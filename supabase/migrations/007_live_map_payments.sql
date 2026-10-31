-- Taxi Cerca | Mapa en vivo, métodos de pago, estado de conductores y servicios para el admin.
-- Solo se ofrecen servicios a conductores conectados que NO estén en servicio y sean los más cercanos.
-- Ejecutar completo en el SQL Editor de Supabase (después de 006).

-- 1) Método de pago en el viaje -----------------------------------------------------------------------
alter table public.rides add column if not exists payment_method text;
alter table public.rides drop constraint if exists ride_payment_method_check;
alter table public.rides add constraint ride_payment_method_check
  check (payment_method is null or payment_method in ('nequi','transferencia','datafono','bancolombia','breb'));

drop function if exists public.ride_create(text, text, double precision, double precision, text, double precision, double precision);

create or replace function public.ride_create(p_token text, p_label text, p_lat double precision, p_lng double precision, p_destination text,
  p_dest_lat double precision default null, p_dest_lng double precision default null, p_payment text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']); v_ride public.rides%rowtype;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Ubicación de recogida no válida.'; end if;
  if (p_dest_lat is null) <> (p_dest_lng is null) or p_dest_lat not between -90 and 90 or p_dest_lng not between -180 and 180 then raise exception 'Coordenadas de destino no válidas.'; end if;
  if p_payment is null or p_payment not in ('nequi','transferencia','datafono','bancolombia','breb') then raise exception 'Elige un método de pago.'; end if;
  if exists (select 1 from public.rides where passenger_id = v_me and status in ('pending','accepted','in_progress')) then
    raise exception 'Ya tienes un viaje activo.';
  end if;
  insert into public.rides(passenger_id, pickup_label, pickup_lat, pickup_lng, destination_label, dest_lat, dest_lng, payment_method, status)
  values (v_me, left(coalesce(nullif(trim(p_label), ''), 'Ubicación actual'), 200), p_lat, p_lng,
          left(nullif(trim(coalesce(p_destination, '')), ''), 200), p_dest_lat, p_dest_lng, p_payment, 'pending')
  returning * into v_ride;
  return to_jsonb(v_ride);
end $$;

-- 2) Pasajero: su viaje incluye método de pago y coordenadas ------------------------------------------
create or replace function public.my_rides(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']); v_hist jsonb; v_active jsonb; v_drv jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v_hist from (
    select id, pickup_label, destination_label, status, created_at, driver_id, payment_method from public.rides
    where passenger_id = v_me order by created_at desc limit 10) x;
  select to_jsonb(r) into v_active from (
    select id, pickup_label, destination_label, status, created_at, driver_id, payment_method, pickup_lat, pickup_lng, dest_lat, dest_lng from public.rides
    where passenger_id = v_me and status in ('pending','accepted','in_progress') order by created_at desc limit 1) r;
  if v_active is not null and (v_active->>'driver_id') is not null then
    select jsonb_build_object('driver_name', p.full_name, 'driver_phone', p.phone, 'vehicle_make', d.vehicle_make,
      'vehicle_model', d.vehicle_model, 'vehicle_color', d.vehicle_color, 'plate', d.plate)
    into v_drv from public.profiles p left join public.driver_details d on d.driver_id = p.id
    where p.id = (v_active->>'driver_id')::uuid;
    v_active := v_active || jsonb_build_object('driver_info', v_drv);
  end if;
  return jsonb_build_object('history', v_hist, 'active', v_active);
end $$;

-- 3) Conductor: servicio activo con datos del pasajero ------------------------------------------------
create or replace function public.driver_state(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  return jsonb_build_object(
    'active_ride', (select to_jsonb(r) || jsonb_build_object('passenger_name', p.full_name, 'passenger_phone', p.phone)
                    from public.rides r join public.profiles p on p.id = r.passenger_id
                    where r.driver_id = v_me and r.status in ('accepted','in_progress') order by r.created_at desc limit 1),
    'documents', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc), '[]'::jsonb) from public.driver_documents d where d.driver_id = v_me),
    'location', (select jsonb_build_object('lat', l.lat, 'lng', l.lng, 'is_online', l.is_online, 'updated_at', l.updated_at) from public.driver_locations l where l.driver_id = v_me)
  );
end $$;

-- 4) Asignación: solo conductores conectados, SIN servicio activo y los más cercanos -------------------
create or replace function public.available_ride_requests(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']); v_out jsonb;
begin
  if exists (select 1 from public.rides where driver_id = v_me and status in ('accepted','in_progress')) then return '[]'::jsonb; end if;
  if not exists (select 1 from public.driver_locations where driver_id = v_me and is_online and lat is not null and lng is not null) then
    return '[]'::jsonb;
  end if;
  with candidates as (
    select r.id as ride_id, p.full_name as p_name, p.phone as p_phone, r.pickup_label, r.pickup_lat, r.pickup_lng,
           r.destination_label, r.dest_lat, r.dest_lng, r.payment_method, r.created_at as created, dl.driver_id as cand,
           public.distance_km(dl.lat, dl.lng, r.pickup_lat, r.pickup_lng) as km,
           row_number() over (partition by r.id order by public.distance_km(dl.lat, dl.lng, r.pickup_lat, r.pickup_lng), dl.driver_id) as rnk
    from public.rides r
    join public.profiles p on p.id = r.passenger_id
    join public.driver_locations dl on dl.is_online and dl.lat is not null and dl.lng is not null
    join public.profiles dp on dp.id = dl.driver_id and dp.role = 'driver'
    where r.status = 'pending' and dl.updated_at > now() - interval '45 seconds'
      and not exists (select 1 from public.rides b where b.driver_id = dl.driver_id and b.status in ('accepted','in_progress'))
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', c.ride_id, 'passenger_name', c.p_name, 'passenger_phone', c.p_phone,
    'pickup_label', c.pickup_label, 'pickup_lat', c.pickup_lat, 'pickup_lng', c.pickup_lng,
    'destination_label', c.destination_label, 'dest_lat', c.dest_lat, 'dest_lng', c.dest_lng, 'payment_method', c.payment_method,
    'created_at', c.created, 'distance_km', c.km) order by c.created), '[]'::jsonb)
  into v_out from candidates c where c.cand = v_me and c.rnk = 1 and c.km <= 20;
  return v_out;
end $$;

create or replace function public.accept_ride(p_token text, p_ride_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
  v_ride public.rides%rowtype; v_nearest uuid; v_loc public.driver_locations%rowtype;
begin
  select * into v_ride from public.rides where id = p_ride_id for update;
  if not found or v_ride.status <> 'pending' then raise exception 'Esta solicitud ya no está disponible.'; end if;
  if exists (select 1 from public.rides where driver_id = v_me and status in ('accepted','in_progress')) then raise exception 'Ya tienes un servicio en curso.'; end if;
  select * into v_loc from public.driver_locations where driver_id = v_me and is_online and lat is not null and lng is not null;
  if not found then raise exception 'Conéctate y comparte tu ubicación para aceptar.'; end if;
  select dl.driver_id into v_nearest from public.driver_locations dl
  join public.profiles p on p.id = dl.driver_id and p.role = 'driver'
  where dl.is_online and dl.lat is not null and dl.lng is not null and dl.updated_at > now() - interval '45 seconds'
    and not exists (select 1 from public.rides b where b.driver_id = dl.driver_id and b.status in ('accepted','in_progress'))
  order by public.distance_km(dl.lat, dl.lng, v_ride.pickup_lat, v_ride.pickup_lng), dl.driver_id limit 1;
  if v_nearest is distinct from v_me then raise exception 'Otro conductor está más cerca de este pasajero.'; end if;
  if public.distance_km(v_loc.lat, v_loc.lng, v_ride.pickup_lat, v_ride.pickup_lng) > 20 then raise exception 'El viaje está fuera del radio de servicio.'; end if;
  update public.rides set driver_id = v_me, status = 'accepted', accepted_at = now() where id = p_ride_id and status = 'pending';
  if not found then raise exception 'La solicitud fue tomada por otro conductor.'; end if;
end $$;

-- 5) Administrador: estado de conductores, mapa en vivo y servicios -----------------------------------
create or replace function public.admin_dashboard(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return jsonb_build_object(
    'users_count', (select count(*) from public.profiles where role = 'user'),
    'rides_count', (select count(*) from public.rides),
    'drivers', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'username', p.username, 'phone', p.phone, 'created_at', p.created_at,
        'status', case when ar.id is not null then 'in_service'
                       when l.is_online and l.updated_at > now() - interval '45 seconds' then 'available'
                       else 'offline' end,
        'lat', l.lat, 'lng', l.lng, 'last_seen', l.updated_at,
        'active_ride', case when ar.id is null then null else jsonb_build_object(
            'id', ar.id, 'status', ar.status, 'passenger_name', pp.full_name, 'passenger_phone', pp.phone,
            'pickup_label', ar.pickup_label, 'destination_label', ar.destination_label, 'payment_method', ar.payment_method) end,
        'driver_details', (select to_jsonb(d) - 'driver_id' from public.driver_details d where d.driver_id = p.id),
        'driver_documents', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'drive_url', x.drive_url) order by x.created_at), '[]'::jsonb) from public.driver_documents x where x.driver_id = p.id)
      ) order by p.created_at desc), '[]'::jsonb)
      from public.profiles p
      left join public.driver_locations l on l.driver_id = p.id
      left join lateral (select r.* from public.rides r where r.driver_id = p.id and r.status in ('accepted','in_progress') order by r.created_at desc limit 1) ar on true
      left join public.profiles pp on pp.id = ar.passenger_id
      where p.role = 'driver')
  );
end $$;

-- Conductores conectados (ubicación reciente) y solicitudes pendientes, para el mapa en vivo.
create or replace function public.admin_live_map(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return jsonb_build_object(
    'drivers', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'plate', d.plate, 'lat', l.lat, 'lng', l.lng, 'updated_at', l.updated_at,
        'status', case when ar.id is not null then 'in_service' else 'available' end,
        'passenger_name', pp.full_name, 'ride_status', ar.status, 'destination_label', ar.destination_label)), '[]'::jsonb)
      from public.driver_locations l
      join public.profiles p on p.id = l.driver_id and p.role = 'driver'
      left join public.driver_details d on d.driver_id = p.id
      left join lateral (select r.* from public.rides r where r.driver_id = p.id and r.status in ('accepted','in_progress') order by r.created_at desc limit 1) ar on true
      left join public.profiles pp on pp.id = ar.passenger_id
      where l.is_online and l.lat is not null and l.lng is not null and l.updated_at > now() - interval '45 seconds'),
    'pending', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'passenger_name', pp.full_name, 'pickup_label', r.pickup_label, 'lat', r.pickup_lat, 'lng', r.pickup_lng,
        'dest_lat', r.dest_lat, 'dest_lng', r.dest_lng, 'payment_method', r.payment_method, 'created_at', r.created_at)), '[]'::jsonb)
      from public.rides r join public.profiles pp on pp.id = r.passenger_id where r.status = 'pending')
  );
end $$;

-- Últimos 100 servicios con cliente, conductor, estado y método de pago.
create or replace function public.admin_services(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) from (
    select r.id, r.status, r.created_at, r.accepted_at, r.completed_at, r.pickup_label, r.pickup_lat, r.pickup_lng,
           r.destination_label, r.dest_lat, r.dest_lng, r.payment_method,
           pp.full_name as passenger_name, pp.phone as passenger_phone,
           dp.full_name as driver_name, dp.phone as driver_phone, dd.plate as driver_plate
    from public.rides r
    join public.profiles pp on pp.id = r.passenger_id
    left join public.profiles dp on dp.id = r.driver_id
    left join public.driver_details dd on dd.driver_id = r.driver_id
    order by r.created_at desc limit 100) x);
end $$;

revoke all on function
  public.ride_create(text,text,double precision,double precision,text,double precision,double precision,text),
  public.my_rides(text), public.driver_state(text), public.available_ride_requests(text), public.accept_ride(text,uuid),
  public.admin_dashboard(text), public.admin_live_map(text), public.admin_services(text)
from public;
grant execute on function
  public.ride_create(text,text,double precision,double precision,text,double precision,double precision,text),
  public.my_rides(text), public.driver_state(text), public.available_ride_requests(text), public.accept_ride(text,uuid),
  public.admin_dashboard(text), public.admin_live_map(text), public.admin_services(text)
to anon, authenticated;

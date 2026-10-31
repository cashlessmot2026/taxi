-- Taxi Cerca | Tarifas mínimas por sector, valor por km, cotización del conductor, propina y contador de recorrido.
-- Ejecutar completo en el SQL Editor de Supabase (después de 008).

-- 1) Tarifas y ajustes --------------------------------------------------------------------------------
create table if not exists public.fare_sectors (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  min_fare integer not null check (min_fare >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists fare_sectors_name_idx on public.fare_sectors (lower(name));
create table if not exists public.app_settings (key text primary key, value text not null);
insert into public.app_settings(key, value) values ('price_per_km', '0') on conflict (key) do nothing;

alter table public.fare_sectors enable row level security;
alter table public.app_settings enable row level security;
revoke all on public.fare_sectors, public.app_settings from anon, authenticated;

-- 2) Datos nuevos en el viaje ---------------------------------------------------------------------------
alter table public.rides
  add column if not exists sector_id uuid references public.fare_sectors(id) on delete set null,
  add column if not exists sector_name text,
  add column if not exists min_fare integer,
  add column if not exists quote_additional integer,
  add column if not exists quote_total integer,
  add column if not exists tip_amount integer not null default 0,
  add column if not exists use_platform_rate boolean not null default false,
  add column if not exists price_per_km integer,
  add column if not exists distance_km_traveled double precision not null default 0,
  add column if not exists track_lat double precision,
  add column if not exists track_lng double precision,
  add column if not exists started_at timestamptz,
  add column if not exists final_fare integer;
alter table public.rides drop constraint if exists ride_money_check;
alter table public.rides add constraint ride_money_check check (
  tip_amount between 0 and 1000000 and coalesce(quote_additional, 0) between 0 and 10000000 and coalesce(min_fare, 0) >= 0);

-- 3) Administrador: tarifas ---------------------------------------------------------------------------
create or replace function public.admin_fares(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return jsonb_build_object(
    'sectors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'min_fare', min_fare, 'is_active', is_active) order by name), '[]'::jsonb) from public.fare_sectors),
    'price_per_km', coalesce((select value::integer from public.app_settings where key = 'price_per_km'), 0));
end $$;

create or replace function public.admin_save_sector(p_token text, p_id uuid, p_name text, p_min_fare integer, p_active boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']); v_id uuid;
begin
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Escribe el nombre del sector.'; end if;
  if p_min_fare is null or p_min_fare < 0 or p_min_fare > 100000000 then raise exception 'La tarifa mínima no es válida.'; end if;
  begin
    if p_id is null then
      insert into public.fare_sectors(name, min_fare, is_active) values (trim(p_name), p_min_fare, coalesce(p_active, true)) returning id into v_id;
    else
      update public.fare_sectors set name = trim(p_name), min_fare = p_min_fare, is_active = coalesce(p_active, true) where id = p_id returning id into v_id;
      if v_id is null then raise exception 'Sector no encontrado.'; end if;
    end if;
  exception when unique_violation then
    raise exception 'Ya existe un sector con ese nombre.';
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.admin_delete_sector(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin delete from public.fare_sectors where id = p_id; end $$;

create or replace function public.admin_set_price_per_km(p_token text, p_value integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  if p_value is null or p_value < 0 or p_value > 1000000 then raise exception 'El valor por kilómetro no es válido.'; end if;
  insert into public.app_settings(key, value) values ('price_per_km', p_value::text)
  on conflict (key) do update set value = excluded.value;
end $$;

-- Tarifas visibles para clientes, conductores y administración.
create or replace function public.fares_public(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user','driver','admin']);
begin
  return jsonb_build_object(
    'sectors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'min_fare', min_fare) order by name), '[]'::jsonb) from public.fare_sectors where is_active),
    'price_per_km', coalesce((select value::integer from public.app_settings where key = 'price_per_km'), 0));
end $$;

-- 4) Pasajero: solicitar con sector y propina; ajustar propina -----------------------------------------
drop function if exists public.ride_create(text, text, double precision, double precision, text, double precision, double precision, text);

create or replace function public.ride_create(p_token text, p_label text, p_lat double precision, p_lng double precision, p_destination text,
  p_dest_lat double precision default null, p_dest_lng double precision default null, p_payment text default null,
  p_sector_id uuid default null, p_tip integer default 0)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']); v_ride public.rides%rowtype; v_sec public.fare_sectors%rowtype;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Ubicación de recogida no válida.'; end if;
  if (p_dest_lat is null) <> (p_dest_lng is null) or p_dest_lat not between -90 and 90 or p_dest_lng not between -180 and 180 then raise exception 'Coordenadas de destino no válidas.'; end if;
  if p_payment is null or p_payment not in ('efectivo','nequi','transferencia','datafono','bancolombia','breb') then raise exception 'Elige un método de pago.'; end if;
  if coalesce(p_tip, 0) < 0 or coalesce(p_tip, 0) > 1000000 then raise exception 'La propina no es válida.'; end if;
  if p_sector_id is not null then
    select * into v_sec from public.fare_sectors where id = p_sector_id and is_active;
    if not found then raise exception 'El sector elegido ya no está disponible.'; end if;
  end if;
  if exists (select 1 from public.rides where passenger_id = v_me and status in ('pending','accepted','in_progress')) then
    raise exception 'Ya tienes un viaje activo.';
  end if;
  insert into public.rides(passenger_id, pickup_label, pickup_lat, pickup_lng, destination_label, dest_lat, dest_lng, payment_method,
                           sector_id, sector_name, min_fare, tip_amount, status)
  values (v_me, left(coalesce(nullif(trim(p_label), ''), 'Ubicación actual'), 200), p_lat, p_lng,
          left(nullif(trim(coalesce(p_destination, '')), ''), 200), p_dest_lat, p_dest_lng, p_payment,
          v_sec.id, v_sec.name, v_sec.min_fare, coalesce(p_tip, 0), 'pending')
  returning * into v_ride;
  return to_jsonb(v_ride);
end $$;

create or replace function public.ride_set_tip(p_token text, p_ride_id uuid, p_tip integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']);
begin
  if p_tip is null or p_tip < 0 or p_tip > 1000000 then raise exception 'La propina no es válida.'; end if;
  update public.rides set tip_amount = p_tip where id = p_ride_id and passenger_id = v_me and status in ('pending','accepted','in_progress');
  if not found then raise exception 'Ya no puedes cambiar la propina de este viaje.'; end if;
end $$;

create or replace function public.my_rides(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']); v_hist jsonb; v_active jsonb; v_drv jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v_hist from (
    select id, pickup_label, destination_label, status, created_at, driver_id, payment_method, final_fare, tip_amount,
           quote_total, distance_km_traveled, started_at, completed_at, sector_name
    from public.rides where passenger_id = v_me order by created_at desc limit 10) x;
  select to_jsonb(r) into v_active from (
    select id, pickup_label, destination_label, status, created_at, driver_id, payment_method, pickup_lat, pickup_lng, dest_lat, dest_lng,
           sector_name, min_fare, quote_additional, quote_total, tip_amount, use_platform_rate, price_per_km,
           distance_km_traveled, started_at, final_fare
    from public.rides where passenger_id = v_me and status in ('pending','accepted','in_progress') order by created_at desc limit 1) r;
  if v_active is not null and (v_active->>'driver_id') is not null then
    select jsonb_build_object('driver_name', p.full_name, 'driver_phone', p.phone, 'vehicle_make', d.vehicle_make,
      'vehicle_model', d.vehicle_model, 'vehicle_color', d.vehicle_color, 'plate', d.plate)
    into v_drv from public.profiles p left join public.driver_details d on d.driver_id = p.id
    where p.id = (v_active->>'driver_id')::uuid;
    v_active := v_active || jsonb_build_object('driver_info', v_drv);
  end if;
  return jsonb_build_object('history', v_hist, 'active', v_active, 'server_now', now());
end $$;

-- 5) Conductor: cotizar, cobrar con tarifa de la plataforma, contador de kilómetros --------------------
drop function if exists public.accept_ride(text, uuid);

create or replace function public.accept_ride(p_token text, p_ride_id uuid, p_additional integer default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
  v_ride public.rides%rowtype; v_nearest uuid; v_loc public.driver_locations%rowtype;
begin
  if p_additional is not null and (p_additional < 0 or p_additional > 10000000) then raise exception 'El valor adicional no es válido.'; end if;
  select * into v_ride from public.rides where id = p_ride_id for update;
  if not found or v_ride.status <> 'pending' then raise exception 'Esta solicitud ya no está disponible.'; end if;
  if exists (select 1 from public.rides where driver_id = v_me and status in ('accepted','in_progress')) then raise exception 'Ya tienes un servicio en curso.'; end if;
  select * into v_loc from public.driver_locations where driver_id = v_me and is_online and lat is not null and lng is not null;
  if not found then raise exception 'Conéctate y comparte tu ubicación para aceptar.'; end if;
  select dl.driver_id into v_nearest from public.driver_locations dl
  join public.profiles p on p.id = dl.driver_id and p.role = 'driver' and p.is_active
  where dl.is_online and dl.lat is not null and dl.lng is not null and dl.updated_at > now() - interval '45 seconds'
    and not exists (select 1 from public.rides b where b.driver_id = dl.driver_id and b.status in ('accepted','in_progress'))
  order by public.distance_km(dl.lat, dl.lng, v_ride.pickup_lat, v_ride.pickup_lng), dl.driver_id limit 1;
  if v_nearest is distinct from v_me then raise exception 'Otro conductor está más cerca de este pasajero.'; end if;
  if public.distance_km(v_loc.lat, v_loc.lng, v_ride.pickup_lat, v_ride.pickup_lng) > 20 then raise exception 'El viaje está fuera del radio de servicio.'; end if;
  update public.rides set driver_id = v_me, status = 'accepted', accepted_at = now(),
    quote_additional = p_additional,
    quote_total = case when p_additional is null then null else coalesce(min_fare, 0) + p_additional end
  where id = p_ride_id and status = 'pending';
  if not found then raise exception 'La solicitud fue tomada por otro conductor.'; end if;
end $$;

-- Valor aproximado = tarifa mínima del sector + valor adicional que fija el conductor (antes de iniciar el recorrido).
create or replace function public.driver_quote_ride(p_token text, p_ride_id uuid, p_additional integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  if p_additional is null or p_additional < 0 or p_additional > 10000000 then raise exception 'El valor adicional no es válido.'; end if;
  update public.rides set quote_additional = p_additional, quote_total = coalesce(min_fare, 0) + p_additional
  where id = p_ride_id and driver_id = v_me and status = 'accepted';
  if not found then raise exception 'Solo puedes cambiar el valor antes de iniciar el viaje.'; end if;
end $$;

create or replace function public.driver_set_platform_rate(p_token text, p_ride_id uuid, p_use boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  update public.rides set use_platform_rate = coalesce(p_use, false)
  where id = p_ride_id and driver_id = v_me and status in ('accepted','in_progress');
  if not found then raise exception 'No puedes cambiar la tarifa de este servicio.'; end if;
end $$;

create or replace function public.update_driver_ride_status(p_token text, p_ride_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  if p_status not in ('in_progress','completed') then raise exception 'Estado no permitido.'; end if;
  update public.rides set
    status = p_status,
    completed_at = case when p_status = 'completed' then now() else completed_at end,
    started_at = case when p_status = 'in_progress' then now() else started_at end,
    price_per_km = case when p_status = 'in_progress' then coalesce((select value::integer from public.app_settings where key = 'price_per_km'), 0) else price_per_km end,
    track_lat = case when p_status = 'in_progress' then (select l.lat from public.driver_locations l where l.driver_id = v_me) else track_lat end,
    track_lng = case when p_status = 'in_progress' then (select l.lng from public.driver_locations l where l.driver_id = v_me) else track_lng end,
    final_fare = case when p_status = 'completed' then
        (case when use_platform_rate then greatest(coalesce(min_fare, 0), round(distance_km_traveled * coalesce(price_per_km, 0))::integer) else quote_total end)
      else final_fare end
  where id = p_ride_id and driver_id = v_me
    and ((status = 'accepted' and p_status = 'in_progress') or (status = 'in_progress' and p_status = 'completed'));
  if not found then raise exception 'No puedes cambiar el estado de este servicio.'; end if;
end $$;

-- Cada actualización de ubicación suma los kilómetros recorridos del viaje en curso.
-- Se cuenta cuando el conductor se aleja ≥ 20 m del último punto contado (filtra el ruido del GPS).
create or replace function public.driver_set_location(p_token text, p_lat double precision, p_lng double precision, p_online boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
  v_ride_id uuid; v_tlat double precision; v_tlng double precision; v_km double precision;
begin
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng is null or p_lng not between -180 and 180) then raise exception 'Ubicación no válida.'; end if;
  insert into public.driver_locations(driver_id, lat, lng, is_online, updated_at) values (v_me, p_lat, p_lng, coalesce(p_online, false), now())
  on conflict (driver_id) do update set
    lat = coalesce(excluded.lat, public.driver_locations.lat),
    lng = coalesce(excluded.lng, public.driver_locations.lng),
    is_online = excluded.is_online, updated_at = now();
  if p_lat is not null then
    select id, track_lat, track_lng into v_ride_id, v_tlat, v_tlng
    from public.rides where driver_id = v_me and status = 'in_progress' order by created_at desc limit 1;
    if v_ride_id is not null then
      if v_tlat is null or v_tlng is null then
        update public.rides set track_lat = p_lat, track_lng = p_lng where id = v_ride_id;
      else
        v_km := public.distance_km(v_tlat, v_tlng, p_lat, p_lng);
        if v_km >= 0.02 then
          if v_km <= 10 then
            update public.rides set distance_km_traveled = distance_km_traveled + v_km, track_lat = p_lat, track_lng = p_lng where id = v_ride_id;
          else
            update public.rides set track_lat = p_lat, track_lng = p_lng where id = v_ride_id; -- salto de GPS: no se suma
          end if;
        end if;
      end if;
    end if;
  end if;
end $$;

create or replace function public.driver_state(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  return jsonb_build_object(
    'server_now', now(),
    'active_ride', (select to_jsonb(r) - 'track_lat' - 'track_lng' || jsonb_build_object('passenger_name', p.full_name, 'passenger_phone', p.phone)
                    from public.rides r join public.profiles p on p.id = r.passenger_id
                    where r.driver_id = v_me and r.status in ('accepted','in_progress') order by r.created_at desc limit 1),
    'documents', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc), '[]'::jsonb) from public.driver_documents d where d.driver_id = v_me),
    'location', (select jsonb_build_object('lat', l.lat, 'lng', l.lng, 'is_online', l.is_online, 'updated_at', l.updated_at) from public.driver_locations l where l.driver_id = v_me)
  );
end $$;

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
           r.destination_label, r.dest_lat, r.dest_lng, r.payment_method, r.sector_name, r.min_fare, r.tip_amount,
           r.created_at as created, dl.driver_id as cand,
           public.distance_km(dl.lat, dl.lng, r.pickup_lat, r.pickup_lng) as km,
           row_number() over (partition by r.id order by public.distance_km(dl.lat, dl.lng, r.pickup_lat, r.pickup_lng), dl.driver_id) as rnk
    from public.rides r
    join public.profiles p on p.id = r.passenger_id
    join public.driver_locations dl on dl.is_online and dl.lat is not null and dl.lng is not null
    join public.profiles dp on dp.id = dl.driver_id and dp.role = 'driver' and dp.is_active
    where r.status = 'pending' and dl.updated_at > now() - interval '45 seconds'
      and not exists (select 1 from public.rides b where b.driver_id = dl.driver_id and b.status in ('accepted','in_progress'))
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', c.ride_id, 'passenger_name', c.p_name, 'passenger_phone', c.p_phone,
    'pickup_label', c.pickup_label, 'pickup_lat', c.pickup_lat, 'pickup_lng', c.pickup_lng,
    'destination_label', c.destination_label, 'dest_lat', c.dest_lat, 'dest_lng', c.dest_lng, 'payment_method', c.payment_method,
    'sector_name', c.sector_name, 'min_fare', c.min_fare, 'tip_amount', c.tip_amount,
    'created_at', c.created, 'distance_km', c.km) order by c.created), '[]'::jsonb)
  into v_out from candidates c where c.cand = v_me and c.rnk = 1 and c.km <= 20;
  return v_out;
end $$;

-- 6) Administrador: servicios con valores ----------------------------------------------------------------
create or replace function public.admin_services(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) from (
    select r.id, r.status, r.created_at, r.accepted_at, r.completed_at, r.started_at, r.pickup_label, r.pickup_lat, r.pickup_lng,
           r.destination_label, r.dest_lat, r.dest_lng, r.payment_method,
           r.sector_name, r.min_fare, r.quote_total, r.tip_amount, r.use_platform_rate, r.distance_km_traveled, r.final_fare,
           pp.full_name as passenger_name, pp.phone as passenger_phone,
           dp.full_name as driver_name, dp.phone as driver_phone, dd.plate as driver_plate
    from public.rides r
    join public.profiles pp on pp.id = r.passenger_id
    left join public.profiles dp on dp.id = r.driver_id
    left join public.driver_details dd on dd.driver_id = r.driver_id
    order by r.created_at desc limit 100) x);
end $$;

-- 7) Permisos ----------------------------------------------------------------------------------------------
revoke all on function
  public.admin_fares(text), public.admin_save_sector(text,uuid,text,integer,boolean), public.admin_delete_sector(text,uuid),
  public.admin_set_price_per_km(text,integer), public.fares_public(text),
  public.ride_create(text,text,double precision,double precision,text,double precision,double precision,text,uuid,integer),
  public.ride_set_tip(text,uuid,integer), public.my_rides(text), public.accept_ride(text,uuid,integer),
  public.driver_quote_ride(text,uuid,integer), public.driver_set_platform_rate(text,uuid,boolean),
  public.update_driver_ride_status(text,uuid,text), public.driver_set_location(text,double precision,double precision,boolean),
  public.driver_state(text), public.available_ride_requests(text), public.admin_services(text)
from public;
grant execute on function
  public.admin_fares(text), public.admin_save_sector(text,uuid,text,integer,boolean), public.admin_delete_sector(text,uuid),
  public.admin_set_price_per_km(text,integer), public.fares_public(text),
  public.ride_create(text,text,double precision,double precision,text,double precision,double precision,text,uuid,integer),
  public.ride_set_tip(text,uuid,integer), public.my_rides(text), public.accept_ride(text,uuid,integer),
  public.driver_quote_ride(text,uuid,integer), public.driver_set_platform_rate(text,uuid,boolean),
  public.update_driver_ride_status(text,uuid,text), public.driver_set_location(text,double precision,double precision,boolean),
  public.driver_state(text), public.available_ride_requests(text), public.admin_services(text)
to anon, authenticated;

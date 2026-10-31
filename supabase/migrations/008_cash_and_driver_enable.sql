-- Taxi Cerca | Pago en efectivo y habilitar / deshabilitar conductores.
-- Ejecutar completo en el SQL Editor de Supabase (después de 007).

-- 1) Efectivo como método de pago ---------------------------------------------------------------------
alter table public.rides drop constraint if exists ride_payment_method_check;
alter table public.rides add constraint ride_payment_method_check
  check (payment_method is null or payment_method in ('efectivo','nequi','transferencia','datafono','bancolombia','breb'));

create or replace function public.ride_create(p_token text, p_label text, p_lat double precision, p_lng double precision, p_destination text,
  p_dest_lat double precision default null, p_dest_lng double precision default null, p_payment text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']); v_ride public.rides%rowtype;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Ubicación de recogida no válida.'; end if;
  if (p_dest_lat is null) <> (p_dest_lng is null) or p_dest_lat not between -90 and 90 or p_dest_lng not between -180 and 180 then raise exception 'Coordenadas de destino no válidas.'; end if;
  if p_payment is null or p_payment not in ('efectivo','nequi','transferencia','datafono','bancolombia','breb') then raise exception 'Elige un método de pago.'; end if;
  if exists (select 1 from public.rides where passenger_id = v_me and status in ('pending','accepted','in_progress')) then
    raise exception 'Ya tienes un viaje activo.';
  end if;
  insert into public.rides(passenger_id, pickup_label, pickup_lat, pickup_lng, destination_label, dest_lat, dest_lng, payment_method, status)
  values (v_me, left(coalesce(nullif(trim(p_label), ''), 'Ubicación actual'), 200), p_lat, p_lng,
          left(nullif(trim(coalesce(p_destination, '')), ''), 200), p_dest_lat, p_dest_lng, p_payment, 'pending')
  returning * into v_ride;
  return to_jsonb(v_ride);
end $$;

-- 2) Cuentas habilitadas / deshabilitadas ---------------------------------------------------------------
alter table public.profiles add column if not exists is_active boolean not null default true;

-- Una cuenta deshabilitada no puede usar ninguna función, aunque conserve un token.
create or replace function public._require_role(p_token text, p_roles text[])
returns uuid language plpgsql stable security definer set search_path = public, extensions as $$
declare v_id uuid; v_role text;
begin
  select p.id, p.role into v_id, v_role
  from public.app_sessions s join public.profiles p on p.id = s.user_id
  where s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and s.expires_at > now() and p.is_active;
  if v_id is null then raise exception 'Sesión inválida o vencida. Inicia sesión de nuevo.'; end if;
  if not (v_role = any(p_roles)) then raise exception 'No tienes permisos para esta acción.'; end if;
  return v_id;
end $$;

create or replace function public.app_login(p_email text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_key text := lower(trim(coalesce(p_email, ''))); v_user public.profiles%rowtype; v_ok boolean;
begin
  delete from public.login_attempts where attempted_at < now() - interval '1 day';
  if (select count(*) from public.login_attempts where email = v_key and attempted_at > now() - interval '15 minutes') >= 5 then
    return jsonb_build_object('error', 'Demasiados intentos fallidos. Espera 15 minutos e inténtalo de nuevo.');
  end if;
  select * into v_user from public.profiles where lower(email) = v_key or lower(username) = v_key limit 1;
  if found and v_user.password_hash is not null then
    v_ok := crypt(coalesce(p_password, ''), v_user.password_hash) = v_user.password_hash;
  else
    perform crypt(coalesce(p_password, ''), gen_salt('bf', 10));
    v_ok := false;
  end if;
  if not v_ok then
    insert into public.login_attempts(email) values (v_key);
    return jsonb_build_object('error', 'Usuario o contraseña incorrectos.');
  end if;
  if not v_user.is_active then
    return jsonb_build_object('error', 'Tu cuenta está deshabilitada. Contacta a administración.');
  end if;
  delete from public.login_attempts where email = v_key;
  return jsonb_build_object('token', public._new_session(v_user.id), 'profile', public._profile_json(v_user.id));
end $$;

create or replace function public.admin_set_driver_active(p_token text, p_driver_id uuid, p_active boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  if not exists (select 1 from public.profiles where id = p_driver_id and role = 'driver') then raise exception 'Conductor no encontrado.'; end if;
  if not coalesce(p_active, true) and exists (select 1 from public.rides where driver_id = p_driver_id and status in ('accepted','in_progress')) then
    raise exception 'Este conductor tiene un servicio en curso. Deshabilítalo cuando termine.';
  end if;
  update public.profiles set is_active = coalesce(p_active, true) where id = p_driver_id;
  if not coalesce(p_active, true) then
    delete from public.app_sessions where user_id = p_driver_id;
    update public.driver_locations set is_online = false, updated_at = now() where driver_id = p_driver_id;
  end if;
  return jsonb_build_object('ok', true, 'is_active', coalesce(p_active, true));
end $$;

-- 3) Los conductores deshabilitados no reciben ni toman servicios; el admin ve su estado ------------
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
    join public.profiles dp on dp.id = dl.driver_id and dp.role = 'driver' and dp.is_active
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
  join public.profiles p on p.id = dl.driver_id and p.role = 'driver' and p.is_active
  where dl.is_online and dl.lat is not null and dl.lng is not null and dl.updated_at > now() - interval '45 seconds'
    and not exists (select 1 from public.rides b where b.driver_id = dl.driver_id and b.status in ('accepted','in_progress'))
  order by public.distance_km(dl.lat, dl.lng, v_ride.pickup_lat, v_ride.pickup_lng), dl.driver_id limit 1;
  if v_nearest is distinct from v_me then raise exception 'Otro conductor está más cerca de este pasajero.'; end if;
  if public.distance_km(v_loc.lat, v_loc.lng, v_ride.pickup_lat, v_ride.pickup_lng) > 20 then raise exception 'El viaje está fuera del radio de servicio.'; end if;
  update public.rides set driver_id = v_me, status = 'accepted', accepted_at = now() where id = p_ride_id and status = 'pending';
  if not found then raise exception 'La solicitud fue tomada por otro conductor.'; end if;
end $$;

create or replace function public.admin_dashboard(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return jsonb_build_object(
    'users_count', (select count(*) from public.profiles where role = 'user'),
    'rides_count', (select count(*) from public.rides),
    'drivers', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'username', p.username, 'phone', p.phone, 'created_at', p.created_at,
        'is_active', p.is_active,
        'status', case when not p.is_active then 'disabled'
                       when ar.id is not null then 'in_service'
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
      join public.profiles p on p.id = l.driver_id and p.role = 'driver' and p.is_active
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

revoke all on function
  public.ride_create(text,text,double precision,double precision,text,double precision,double precision,text),
  public.app_login(text,text), public.admin_set_driver_active(text,uuid,boolean),
  public.available_ride_requests(text), public.accept_ride(text,uuid), public.admin_dashboard(text), public.admin_live_map(text)
from public;
grant execute on function
  public.ride_create(text,text,double precision,double precision,text,double precision,double precision,text),
  public.app_login(text,text), public.admin_set_driver_active(text,uuid,boolean),
  public.available_ride_requests(text), public.accept_ride(text,uuid), public.admin_dashboard(text), public.admin_live_map(text)
to anon, authenticated;
revoke all on function public._require_role(text, text[]) from public, anon, authenticated;

-- =====================================================================================================
-- Taxis Teleclub | SCHEMA COMPLETO (base de datos + funciones + permisos)
-- Pegar y ejecutar COMPLETO en el SQL Editor de Supabase. Se puede ejecutar varias veces.
--
-- Qué crea:
--   * Tablas: profiles, driver_details, driver_documents, driver_locations, rides, app_sessions,
--             login_attempts, fare_sectors, app_settings.
--   * Autenticación propia (sin Supabase Auth): contraseñas con hash bcrypt, sesiones con token.
--   * Todas las tablas quedan CERRADAS a la API pública; la app solo usa las funciones RPC de abajo.
--   * Tarifas mínimas por ciudad/sector (sección final) y valor por kilómetro.
--
-- Generado a partir de las migraciones 001–009 del proyecto.
-- =====================================================================================================

create extension if not exists pgcrypto;

-- 0) Limpieza de versiones antiguas (basadas en Supabase Auth) ------------------------------------------
do $$ begin
  execute 'drop trigger if exists on_auth_user_created on auth.users';
exception when others then null; end $$;
-- Políticas RLS antiguas (basadas en auth.uid() / is_admin()): ya no se usan; todo el acceso es por funciones RPC.
do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies
           where schemaname = 'public' and tablename in ('profiles','driver_details','driver_documents','driver_locations','rides')
  loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;
drop function if exists public.handle_new_user();
drop function if exists public.is_admin() cascade;
drop function if exists public.get_ride_driver(uuid);
drop function if exists public.cancel_my_ride(uuid);
drop function if exists public.accept_ride(uuid);
drop function if exists public.accept_ride(text, uuid);
drop function if exists public.update_driver_ride_status(uuid, text);
drop function if exists public.available_ride_requests();
drop function if exists public.ride_create(text, text, double precision, double precision, text);
drop function if exists public.ride_create(text, text, double precision, double precision, text, double precision, double precision);
drop function if exists public.ride_create(text, text, double precision, double precision, text, double precision, double precision, text);

-- 1) Tablas ---------------------------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key default gen_random_uuid(),
  full_name text not null default '',
  email text unique,
  username text,
  phone text not null default '',
  role text not null default 'user' check (role in ('user','driver','admin')),
  password_hash text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.profiles drop constraint if exists profiles_id_fkey;
alter table public.profiles alter column id set default gen_random_uuid();
alter table public.profiles add column if not exists password_hash text;
alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists is_active boolean not null default true;
create unique index if not exists profiles_email_lower_idx on public.profiles (lower(email));
create unique index if not exists profiles_username_lower_idx on public.profiles (lower(username)) where username is not null;

create table if not exists public.driver_details (
  driver_id uuid primary key references public.profiles(id) on delete cascade,
  vehicle_make text not null default '',
  vehicle_model text not null default '',
  vehicle_color text not null default '',
  plate text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.driver_documents (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  drive_url text not null,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  constraint driver_documents_https check (drive_url like 'https://%')
);
create index if not exists driver_documents_driver_idx on public.driver_documents(driver_id);

create table if not exists public.driver_locations (
  driver_id uuid primary key references public.profiles(id) on delete cascade,
  lat double precision,
  lng double precision,
  is_online boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint driver_lat_range check (lat is null or lat between -90 and 90),
  constraint driver_lng_range check (lng is null or lng between -180 and 180)
);
create index if not exists driver_locations_online_idx on public.driver_locations(is_online) where is_online = true;

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

create table if not exists public.rides (
  id uuid primary key default gen_random_uuid(),
  passenger_id uuid not null references public.profiles(id),
  driver_id uuid references public.profiles(id),
  pickup_label text not null,
  pickup_lat double precision not null,
  pickup_lng double precision not null,
  destination_label text,
  status text not null default 'pending' check (status in ('pending','accepted','in_progress','completed','cancelled')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  completed_at timestamptz,
  constraint ride_pickup_lat_range check (pickup_lat between -90 and 90),
  constraint ride_pickup_lng_range check (pickup_lng between -180 and 180)
);
alter table public.rides
  add column if not exists dest_lat double precision,
  add column if not exists dest_lng double precision,
  add column if not exists payment_method text,
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
alter table public.rides drop constraint if exists ride_dest_range;
alter table public.rides add constraint ride_dest_range check (
  (dest_lat is null and dest_lng is null) or
  (dest_lat is not null and dest_lng is not null and dest_lat between -90 and 90 and dest_lng between -180 and 180));
alter table public.rides drop constraint if exists ride_payment_method_check;
alter table public.rides add constraint ride_payment_method_check
  check (payment_method is null or payment_method in ('efectivo','nequi','transferencia','datafono','bancolombia','breb'));
alter table public.rides drop constraint if exists ride_money_check;
alter table public.rides add constraint ride_money_check check (
  tip_amount between 0 and 1000000 and coalesce(quote_additional, 0) between 0 and 10000000 and coalesce(min_fare, 0) >= 0);
create index if not exists rides_passenger_created_idx on public.rides(passenger_id, created_at desc);
create index if not exists rides_driver_status_idx on public.rides(driver_id, status);
create index if not exists rides_status_created_idx on public.rides(status, created_at);

create table if not exists public.app_sessions (
  token_hash text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists app_sessions_user_idx on public.app_sessions(user_id);

create table if not exists public.login_attempts (
  id bigserial primary key,
  email text not null,
  attempted_at timestamptz not null default now()
);
create index if not exists login_attempts_email_idx on public.login_attempts(email, attempted_at);

-- 2) Seguridad: las tablas no son accesibles desde la API pública -------------------------------------------
alter table public.profiles enable row level security;
alter table public.driver_details enable row level security;
alter table public.driver_documents enable row level security;
alter table public.driver_locations enable row level security;
alter table public.rides enable row level security;
alter table public.app_sessions enable row level security;
alter table public.login_attempts enable row level security;
alter table public.fare_sectors enable row level security;
alter table public.app_settings enable row level security;
revoke all on public.profiles, public.driver_details, public.driver_documents, public.driver_locations, public.rides,
  public.app_sessions, public.login_attempts, public.fare_sectors, public.app_settings from anon, authenticated;
revoke all on sequence public.login_attempts_id_seq from anon, authenticated;

-- 3) Funciones ------------------------------------------------------------------------------------------------
-- _require_role
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

-- _new_session
create or replace function public._new_session(p_user uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_token text := encode(gen_random_bytes(32), 'hex');
begin
  delete from public.app_sessions where expires_at < now();
  insert into public.app_sessions(token_hash, user_id, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), p_user, now() + interval '30 days');
  return v_token;
end $$;

-- _profile_json
create or replace function public._profile_json(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'full_name', full_name, 'email', email, 'phone', phone, 'role', role, 'created_at', created_at)
  from public.profiles where id = p_user
$$;

-- distance_km
create or replace function public.distance_km(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision
language sql
immutable
strict
as $$
  select 6371 * 2 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

-- app_register
create or replace function public.app_register(p_name text, p_email text, p_phone text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_email text := lower(trim(coalesce(p_email, ''))); v_id uuid;
begin
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Escribe tu nombre completo.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo electrónico no válido.'; end if;
  if length(coalesce(p_password, '')) < 5 then raise exception 'Usa una contraseña de al menos 5 caracteres.'; end if;
  if length(p_password) > 72 then raise exception 'La contraseña no puede superar 72 caracteres.'; end if;
  if exists (select 1 from public.profiles where lower(email) = v_email) then raise exception 'Ese correo ya está registrado.'; end if;
  insert into public.profiles(full_name, email, phone, role, password_hash)
  values (trim(p_name), v_email, trim(coalesce(p_phone, '')), 'user', crypt(p_password, gen_salt('bf', 10)))
  returning id into v_id;
  return jsonb_build_object('token', public._new_session(v_id), 'profile', public._profile_json(v_id));
end $$;

-- app_login
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

-- app_me
create or replace function public.app_me(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_id uuid := public._require_role(p_token, array['user','driver','admin']);
begin return public._profile_json(v_id); end $$;

-- app_logout
create or replace function public.app_logout(p_token text)
returns void language sql security definer set search_path = public, extensions as $$
  delete from public.app_sessions where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

-- ride_create
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

-- my_rides
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

-- cancel_my_ride
create or replace function public.cancel_my_ride(p_token text, p_ride_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']);
begin
  update public.rides set status = 'cancelled' where id = p_ride_id and passenger_id = v_me and status = 'pending';
  if not found then raise exception 'Solo puedes cancelar una solicitud que aún no ha sido aceptada.'; end if;
end $$;

-- driver_set_location
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

-- driver_state
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

-- available_ride_requests
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

-- accept_ride
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

-- update_driver_ride_status
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
        (case when use_platform_rate
              then greatest(coalesce(min_fare, 0), round(distance_km_traveled * coalesce(price_per_km, 0))::integer)
              else coalesce(quote_total, greatest(coalesce(min_fare, 0), round(distance_km_traveled * coalesce(price_per_km, 0))::integer)) end)
      else final_fare end
  where id = p_ride_id and driver_id = v_me
    and ((status = 'accepted' and p_status = 'in_progress') or (status = 'in_progress' and p_status = 'completed'));
  if not found then raise exception 'No puedes cambiar el estado de este servicio.'; end if;
end $$;

-- admin_dashboard
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

-- admin_create_driver
create or replace function public.admin_create_driver(p_token text, p_name text, p_email text, p_phone text, p_password text,
  p_make text, p_model text, p_color text, p_plate text, p_docs jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
  v_email text := lower(trim(coalesce(p_email, ''))); v_id uuid; v_doc jsonb;
begin
  if length(trim(coalesce(p_name, ''))) < 2 or length(trim(coalesce(p_phone, ''))) < 3 then raise exception 'Completa nombre, correo y teléfono.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo electrónico no válido.'; end if;
  if length(coalesce(p_password, '')) < 5 or length(p_password) > 72 then raise exception 'La contraseña debe tener entre 5 y 72 caracteres.'; end if;
  if exists (select 1 from public.profiles where lower(email) = v_email) then raise exception 'Ese correo ya está registrado.'; end if;
  if jsonb_typeof(coalesce(p_docs, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_docs, '[]'::jsonb)) > 10 then raise exception 'Puedes asociar máximo 10 documentos.'; end if;
  for v_doc in select * from jsonb_array_elements(coalesce(p_docs, '[]'::jsonb)) loop
    if coalesce(v_doc->>'drive_url', '') !~ '^https://(drive|docs)\.google\.com/' or length(trim(coalesce(v_doc->>'title', ''))) = 0 then
      raise exception 'Cada documento debe tener un nombre y un enlace HTTPS de Google Drive o Google Docs.';
    end if;
  end loop;
  insert into public.profiles(full_name, email, phone, role, password_hash)
  values (trim(p_name), v_email, trim(p_phone), 'driver', crypt(p_password, gen_salt('bf', 10))) returning id into v_id;
  insert into public.driver_details(driver_id, vehicle_make, vehicle_model, vehicle_color, plate)
  values (v_id, trim(coalesce(p_make, '')), trim(coalesce(p_model, '')), trim(coalesce(p_color, '')), upper(trim(coalesce(p_plate, ''))));
  insert into public.driver_documents(driver_id, title, drive_url, created_by)
  select v_id, trim(d->>'title'), trim(d->>'drive_url'), v_me from jsonb_array_elements(coalesce(p_docs, '[]'::jsonb)) d;
  return jsonb_build_object('ok', true, 'driver_id', v_id);
end $$;

-- admin_set_password
create or replace function public.admin_set_password(p_token text, p_user_id uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  if length(coalesce(p_password, '')) < 5 or length(p_password) > 72 then raise exception 'La contraseña debe tener entre 5 y 72 caracteres.'; end if;
  update public.profiles set password_hash = crypt(p_password, gen_salt('bf', 10)) where id = p_user_id;
  if not found then raise exception 'Usuario no encontrado.'; end if;
  delete from public.app_sessions where user_id = p_user_id;
end $$;

-- admin_update_driver
create or replace function public.admin_update_driver(p_token text, p_driver_id uuid, p_name text, p_email text, p_phone text,
  p_username text, p_password text, p_make text, p_model text, p_color text, p_plate text, p_docs jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_user text := nullif(lower(trim(coalesce(p_username, ''))), '');
  v_doc jsonb;
begin
  if not exists (select 1 from public.profiles where id = p_driver_id and role = 'driver') then raise exception 'Conductor no encontrado.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 or length(trim(coalesce(p_phone, ''))) < 3 then raise exception 'Completa nombre y teléfono.'; end if;
  if v_email is null and v_user is null then raise exception 'Indica un correo o un usuario para que pueda iniciar sesión.'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo electrónico no válido.'; end if;
  if v_user is not null and v_user !~ '^[a-z0-9._-]{3,30}$' then raise exception 'El usuario debe tener de 3 a 30 caracteres (letras, números, punto, guion).'; end if;
  if v_email is not null and exists (select 1 from public.profiles where lower(email) = v_email and id <> p_driver_id) then raise exception 'Ese correo ya está en uso.'; end if;
  if v_user is not null and exists (select 1 from public.profiles where lower(username) = v_user and id <> p_driver_id) then raise exception 'Ese usuario ya está en uso.'; end if;
  if length(coalesce(p_password, '')) > 0 and (length(p_password) < 5 or length(p_password) > 72) then raise exception 'La contraseña debe tener entre 5 y 72 caracteres.'; end if;
  if jsonb_typeof(coalesce(p_docs, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_docs, '[]'::jsonb)) > 10 then raise exception 'Puedes asociar máximo 10 documentos.'; end if;
  for v_doc in select * from jsonb_array_elements(coalesce(p_docs, '[]'::jsonb)) loop
    if coalesce(v_doc->>'drive_url', '') !~ '^https://(drive|docs)\.google\.com/' or length(trim(coalesce(v_doc->>'title', ''))) = 0 then
      raise exception 'Cada documento debe tener un nombre y un enlace HTTPS de Google Drive o Google Docs.';
    end if;
  end loop;

  update public.profiles set full_name = trim(p_name), email = v_email, username = v_user, phone = trim(p_phone) where id = p_driver_id;
  if length(coalesce(p_password, '')) > 0 then
    update public.profiles set password_hash = crypt(p_password, gen_salt('bf', 10)) where id = p_driver_id;
    delete from public.app_sessions where user_id = p_driver_id;
  end if;
  insert into public.driver_details(driver_id, vehicle_make, vehicle_model, vehicle_color, plate, updated_at)
  values (p_driver_id, trim(coalesce(p_make, '')), trim(coalesce(p_model, '')), trim(coalesce(p_color, '')), upper(trim(coalesce(p_plate, ''))), now())
  on conflict (driver_id) do update set vehicle_make = excluded.vehicle_make, vehicle_model = excluded.vehicle_model,
    vehicle_color = excluded.vehicle_color, plate = excluded.plate, updated_at = now();
  delete from public.driver_documents where driver_id = p_driver_id;
  insert into public.driver_documents(driver_id, title, drive_url, created_by)
  select p_driver_id, trim(d->>'title'), trim(d->>'drive_url'), v_me from jsonb_array_elements(coalesce(p_docs, '[]'::jsonb)) d;
  return jsonb_build_object('ok', true);
end $$;

-- admin_live_map
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

-- admin_services
create or replace function public.admin_services(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) from (
    select r.id, r.status, r.created_at, r.accepted_at, r.completed_at, r.started_at, r.pickup_label, r.pickup_lat, r.pickup_lng,
           r.destination_label, r.dest_lat, r.dest_lng, r.payment_method,
           r.sector_name, r.min_fare, r.quote_total, r.tip_amount, r.use_platform_rate, r.price_per_km, r.distance_km_traveled, r.final_fare,
           pp.full_name as passenger_name, pp.phone as passenger_phone,
           dp.full_name as driver_name, dp.phone as driver_phone, dd.plate as driver_plate
    from public.rides r
    join public.profiles pp on pp.id = r.passenger_id
    left join public.profiles dp on dp.id = r.driver_id
    left join public.driver_details dd on dd.driver_id = r.driver_id
    order by r.created_at desc limit 100) x);
end $$;

-- admin_set_driver_active
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

-- admin_fares
create or replace function public.admin_fares(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return jsonb_build_object(
    'sectors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'min_fare', min_fare, 'is_active', is_active) order by name), '[]'::jsonb) from public.fare_sectors),
    'price_per_km', coalesce((select value::integer from public.app_settings where key = 'price_per_km'), 0));
end $$;

-- admin_save_sector
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

-- admin_delete_sector
create or replace function public.admin_delete_sector(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin delete from public.fare_sectors where id = p_id; end $$;

-- admin_set_price_per_km
create or replace function public.admin_set_price_per_km(p_token text, p_value integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  if p_value is null or p_value < 0 or p_value > 1000000 then raise exception 'El valor por kilómetro no es válido.'; end if;
  insert into public.app_settings(key, value) values ('price_per_km', p_value::text)
  on conflict (key) do update set value = excluded.value;
end $$;

-- fares_public
create or replace function public.fares_public(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user','driver','admin']);
begin
  return jsonb_build_object(
    'sectors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'min_fare', min_fare) order by name), '[]'::jsonb) from public.fare_sectors where is_active),
    'price_per_km', coalesce((select value::integer from public.app_settings where key = 'price_per_km'), 0));
end $$;

-- ride_set_tip
create or replace function public.ride_set_tip(p_token text, p_ride_id uuid, p_tip integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']);
begin
  if p_tip is null or p_tip < 0 or p_tip > 1000000 then raise exception 'La propina no es válida.'; end if;
  update public.rides set tip_amount = p_tip where id = p_ride_id and passenger_id = v_me and status in ('pending','accepted','in_progress');
  if not found then raise exception 'Ya no puedes cambiar la propina de este viaje.'; end if;
end $$;

-- driver_quote_ride
create or replace function public.driver_quote_ride(p_token text, p_ride_id uuid, p_additional integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  if p_additional is null or p_additional < 0 or p_additional > 10000000 then raise exception 'El valor adicional no es válido.'; end if;
  update public.rides set quote_additional = p_additional, quote_total = coalesce(min_fare, 0) + p_additional
  where id = p_ride_id and driver_id = v_me and status = 'accepted';
  if not found then raise exception 'Solo puedes cambiar el valor antes de iniciar el viaje.'; end if;
end $$;

-- driver_set_platform_rate
create or replace function public.driver_set_platform_rate(p_token text, p_ride_id uuid, p_use boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  update public.rides set use_platform_rate = coalesce(p_use, false)
  where id = p_ride_id and driver_id = v_me and status in ('accepted','in_progress');
  if not found then raise exception 'No puedes cambiar la tarifa de este servicio.'; end if;
end $$;

-- 4) Permisos: solo estas funciones son accesibles desde la app (las que empiezan por _ son internas) ---------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname = any(array['_require_role', '_new_session', '_profile_json', 'distance_km', 'app_register', 'app_login', 'app_me', 'app_logout', 'ride_create', 'my_rides', 'cancel_my_ride', 'driver_set_location', 'driver_state', 'available_ride_requests', 'accept_ride', 'update_driver_ride_status', 'admin_dashboard', 'admin_create_driver', 'admin_set_password', 'admin_update_driver', 'admin_live_map', 'admin_services', 'admin_set_driver_active', 'admin_fares', 'admin_save_sector', 'admin_delete_sector', 'admin_set_price_per_km', 'fares_public', 'ride_set_tip', 'driver_quote_ride', 'driver_set_platform_rate'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    if left(r.proname, 1) <> '_' then
      execute format('grant execute on function %s to anon, authenticated', r.sig);
    end if;
  end loop;
end $$;

-- 5) Tarifas mínimas de taxi por ciudad (ver notas y fuentes abajo) ----------------------------------------------
-- >>> INICIO DE DATOS
insert into public.fare_sectors(name, min_fare, is_active) values
  -- Bogotá D.C. — Decreto 042 de 2026 (en firme desde el 12 de febrero de 2026). Mínima 50 unidades.
  ('Bogotá D.C. — Taxi básico',                         8000, true),
  ('Bogotá D.C. — Taxi con factor de excelencia',        8600, true),
  -- Medellín — Alcaldía de Medellín, vigente desde el 2 de febrero de 2026.
  ('Medellín — Taxi básico',                             8300, true),
  ('Medellín — Taxi eléctrico',                          9500, true),
  ('Medellín — Taxi de lujo',                           12100, true),
  -- Bello (Antioquia) — Resolución 202600002883 de 2026, Secretaría de Movilidad.
  ('Bello — Taxi básico',                                8300, true),
  -- Cali — Decreto 1084 de 2025 (aplica en 2026).
  ('Cali — Taxi nivel básico',                           7100, true),
  ('Cali — Taxi nivel lujo',                             9100, true),
  -- Área Metropolitana de Bucaramanga (Bucaramanga, Floridablanca, Girón, Piedecuesta) — ajuste 2026.
  ('Bucaramanga (área metropolitana) — Taxi',            9100, true),
  -- Santa Marta — decreto municipal 2026 (mínima $8.600; unidad $121).
  ('Santa Marta — Taxi',                                 8600, true),
  -- Tunja — Decreto 590 del 24 de diciembre de 2025.
  ('Tunja — Taxi',                                       5800, true),
  -- Ibagué — tarifa publicada por la Alcaldía (Decreto 0749 de 2024; reportada como vigente en 2026).
  ('Ibagué — Taxi',                                      6600, true),
  -- Cartagena — Decreto 0765 de 2025 (último decreto de tarifas encontrado; recargo nocturno $1.000). VERIFICAR 2026.
  ('Cartagena — Taxi (vigencia 2025, verificar 2026)',  10800, true)
on conflict (lower(name)) do update set min_fare = excluded.min_fare, is_active = true;

-- Verificación
select name, min_fare from public.fare_sectors order by name;

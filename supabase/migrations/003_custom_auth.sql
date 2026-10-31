-- Taxi Cerca | Autenticación propia (sin Supabase Auth ni proveedores externos)
-- Usuarios y contraseñas viven en public.profiles (contraseña con hash bcrypt).
-- La app ya NO accede a las tablas directamente: todo pasa por funciones RPC que validan un token de sesión.
-- Ejecutar completo en el SQL Editor de Supabase (después de 001 y 002).

-- 1) profiles deja de depender de auth.users ---------------------------------------------------------
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user();
alter table public.profiles drop constraint if exists profiles_id_fkey;
alter table public.profiles alter column id set default gen_random_uuid();
alter table public.profiles add column if not exists password_hash text;
create unique index if not exists profiles_email_lower_idx on public.profiles (lower(email));

-- 2) Sesiones e intentos de acceso ------------------------------------------------------------------
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

-- 3) Cerrar el acceso directo a tablas y retirar lo basado en Supabase Auth ----------------------------
drop policy if exists "profile owner or admin reads profiles" on public.profiles;
drop policy if exists "driver or admin reads driver details" on public.driver_details;
drop policy if exists "driver or admin reads documents" on public.driver_documents;
drop policy if exists "driver or admin reads locations" on public.driver_locations;
drop policy if exists "driver inserts own location" on public.driver_locations;
drop policy if exists "driver updates own location" on public.driver_locations;
drop policy if exists "ride participants or admin read rides" on public.rides;
drop policy if exists "passenger creates own ride" on public.rides;

drop function if exists public.available_ride_requests();
drop function if exists public.accept_ride(uuid);
drop function if exists public.update_driver_ride_status(uuid, text);
drop function if exists public.get_ride_driver(uuid);
drop function if exists public.cancel_my_ride(uuid);
drop function if exists public.is_admin();

alter table public.app_sessions enable row level security;
alter table public.login_attempts enable row level security;
alter table public.profiles enable row level security;
alter table public.driver_details enable row level security;
alter table public.driver_documents enable row level security;
alter table public.driver_locations enable row level security;
alter table public.rides enable row level security;
revoke all on public.profiles, public.driver_details, public.driver_documents, public.driver_locations,
  public.rides, public.app_sessions, public.login_attempts from anon, authenticated;
revoke all on sequence public.login_attempts_id_seq from anon, authenticated;

do $$ begin alter publication supabase_realtime drop table public.rides; exception when others then null; end $$;
do $$ begin alter publication supabase_realtime drop table public.profiles; exception when others then null; end $$;
do $$ begin alter publication supabase_realtime drop table public.driver_documents; exception when others then null; end $$;

-- 4) Ayudantes internos (no expuestos a la API) -------------------------------------------------------
create or replace function public._require_role(p_token text, p_roles text[])
returns uuid language plpgsql stable security definer set search_path = public, extensions as $$
declare v_id uuid; v_role text;
begin
  select p.id, p.role into v_id, v_role
  from public.app_sessions s join public.profiles p on p.id = s.user_id
  where s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and s.expires_at > now();
  if v_id is null then raise exception 'Sesión inválida o vencida. Inicia sesión de nuevo.'; end if;
  if not (v_role = any(p_roles)) then raise exception 'No tienes permisos para esta acción.'; end if;
  return v_id;
end $$;

create or replace function public._new_session(p_user uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_token text := encode(gen_random_bytes(32), 'hex');
begin
  delete from public.app_sessions where expires_at < now();
  insert into public.app_sessions(token_hash, user_id, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), p_user, now() + interval '30 days');
  return v_token;
end $$;

create or replace function public._profile_json(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'full_name', full_name, 'email', email, 'phone', phone, 'role', role, 'created_at', created_at)
  from public.profiles where id = p_user
$$;

revoke all on function public._require_role(text, text[]), public._new_session(uuid), public._profile_json(uuid) from public, anon, authenticated;

-- 5) Registro, acceso y sesión ----------------------------------------------------------------------
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

-- Devuelve {error} en lugar de lanzar excepción para que el conteo de intentos fallidos se conserve.
create or replace function public.app_login(p_email text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_email text := lower(trim(coalesce(p_email, ''))); v_user public.profiles%rowtype; v_ok boolean;
begin
  delete from public.login_attempts where attempted_at < now() - interval '1 day';
  if (select count(*) from public.login_attempts where email = v_email and attempted_at > now() - interval '15 minutes') >= 5 then
    return jsonb_build_object('error', 'Demasiados intentos fallidos. Espera 15 minutos e inténtalo de nuevo.');
  end if;
  select * into v_user from public.profiles where lower(email) = v_email;
  if found and v_user.password_hash is not null then
    v_ok := crypt(coalesce(p_password, ''), v_user.password_hash) = v_user.password_hash;
  else
    perform crypt(coalesce(p_password, ''), gen_salt('bf', 10)); -- iguala el tiempo de respuesta
    v_ok := false;
  end if;
  if not v_ok then
    insert into public.login_attempts(email) values (v_email);
    return jsonb_build_object('error', 'Correo o contraseña incorrectos.');
  end if;
  delete from public.login_attempts where email = v_email;
  return jsonb_build_object('token', public._new_session(v_user.id), 'profile', public._profile_json(v_user.id));
end $$;

create or replace function public.app_me(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_id uuid := public._require_role(p_token, array['user','driver','admin']);
begin return public._profile_json(v_id); end $$;

create or replace function public.app_logout(p_token text)
returns void language sql security definer set search_path = public, extensions as $$
  delete from public.app_sessions where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

-- 6) Pasajero ---------------------------------------------------------------------------------------
create or replace function public.ride_create(p_token text, p_label text, p_lat double precision, p_lng double precision, p_destination text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']); v_ride public.rides%rowtype;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Ubicación no válida.'; end if;
  if exists (select 1 from public.rides where passenger_id = v_me and status in ('pending','accepted','in_progress')) then
    raise exception 'Ya tienes un viaje activo.';
  end if;
  insert into public.rides(passenger_id, pickup_label, pickup_lat, pickup_lng, destination_label, status)
  values (v_me, left(coalesce(nullif(trim(p_label), ''), 'Ubicación actual'), 200), p_lat, p_lng, left(nullif(trim(coalesce(p_destination, '')), ''), 200), 'pending')
  returning * into v_ride;
  return to_jsonb(v_ride);
end $$;

create or replace function public.my_rides(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']); v_hist jsonb; v_active jsonb; v_drv jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v_hist from (
    select id, pickup_label, destination_label, status, created_at, driver_id from public.rides
    where passenger_id = v_me order by created_at desc limit 10) x;
  select to_jsonb(r) into v_active from (
    select id, pickup_label, destination_label, status, created_at, driver_id from public.rides
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

create or replace function public.cancel_my_ride(p_token text, p_ride_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']);
begin
  update public.rides set status = 'cancelled' where id = p_ride_id and passenger_id = v_me and status = 'pending';
  if not found then raise exception 'Solo puedes cancelar una solicitud que aún no ha sido aceptada.'; end if;
end $$;

-- 7) Conductor --------------------------------------------------------------------------------------
create or replace function public.driver_set_location(p_token text, p_lat double precision, p_lng double precision, p_online boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng is null or p_lng not between -180 and 180) then raise exception 'Ubicación no válida.'; end if;
  insert into public.driver_locations(driver_id, lat, lng, is_online, updated_at) values (v_me, p_lat, p_lng, coalesce(p_online, false), now())
  on conflict (driver_id) do update set
    lat = coalesce(excluded.lat, public.driver_locations.lat),
    lng = coalesce(excluded.lng, public.driver_locations.lng),
    is_online = excluded.is_online, updated_at = now();
end $$;

create or replace function public.driver_state(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  return jsonb_build_object(
    'active_ride', (select to_jsonb(r) from public.rides r where r.driver_id = v_me and r.status in ('accepted','in_progress') order by r.created_at desc limit 1),
    'documents', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc), '[]'::jsonb) from public.driver_documents d where d.driver_id = v_me),
    'location', (select jsonb_build_object('lat', l.lat, 'lng', l.lng, 'is_online', l.is_online, 'updated_at', l.updated_at) from public.driver_locations l where l.driver_id = v_me)
  );
end $$;

-- Solo entrega solicitudes para las que este conductor es el más cercano (≤ 20 km).
create or replace function public.available_ride_requests(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']); v_out jsonb;
begin
  if not exists (select 1 from public.driver_locations where driver_id = v_me and is_online and lat is not null and lng is not null) then
    return '[]'::jsonb;
  end if;
  with candidates as (
    select r.id as ride_id, p.full_name as p_name, p.phone as p_phone, r.pickup_label, r.pickup_lat, r.pickup_lng,
           r.destination_label, r.created_at as created, dl.driver_id as cand,
           public.distance_km(dl.lat, dl.lng, r.pickup_lat, r.pickup_lng) as km,
           row_number() over (partition by r.id order by public.distance_km(dl.lat, dl.lng, r.pickup_lat, r.pickup_lng), dl.driver_id) as rnk
    from public.rides r
    join public.profiles p on p.id = r.passenger_id
    join public.driver_locations dl on dl.is_online and dl.lat is not null and dl.lng is not null
    join public.profiles dp on dp.id = dl.driver_id and dp.role = 'driver'
    where r.status = 'pending' and dl.updated_at > now() - interval '45 seconds'
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', c.ride_id, 'passenger_name', c.p_name, 'passenger_phone', c.p_phone,
    'pickup_label', c.pickup_label, 'pickup_lat', c.pickup_lat, 'pickup_lng', c.pickup_lng,
    'destination_label', c.destination_label, 'created_at', c.created, 'distance_km', c.km) order by c.created), '[]'::jsonb)
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
  order by public.distance_km(dl.lat, dl.lng, v_ride.pickup_lat, v_ride.pickup_lng), dl.driver_id limit 1;
  if v_nearest is distinct from v_me then raise exception 'Otro conductor está más cerca de este pasajero.'; end if;
  if public.distance_km(v_loc.lat, v_loc.lng, v_ride.pickup_lat, v_ride.pickup_lng) > 20 then raise exception 'El viaje está fuera del radio de servicio.'; end if;
  update public.rides set driver_id = v_me, status = 'accepted', accepted_at = now() where id = p_ride_id and status = 'pending';
  if not found then raise exception 'La solicitud fue tomada por otro conductor.'; end if;
end $$;

create or replace function public.update_driver_ride_status(p_token text, p_ride_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']);
begin
  if p_status not in ('in_progress','completed') then raise exception 'Estado no permitido.'; end if;
  update public.rides set status = p_status, completed_at = case when p_status = 'completed' then now() else completed_at end
  where id = p_ride_id and driver_id = v_me
    and ((status = 'accepted' and p_status = 'in_progress') or (status = 'in_progress' and p_status = 'completed'));
  if not found then raise exception 'No puedes cambiar el estado de este servicio.'; end if;
end $$;

-- 8) Administrador ----------------------------------------------------------------------------------
create or replace function public.admin_dashboard(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return jsonb_build_object(
    'users_count', (select count(*) from public.profiles where role = 'user'),
    'rides_count', (select count(*) from public.rides),
    'drivers', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'phone', p.phone, 'created_at', p.created_at,
        'driver_details', (select to_jsonb(d) - 'driver_id' from public.driver_details d where d.driver_id = p.id),
        'driver_documents', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'drive_url', x.drive_url) order by x.created_at), '[]'::jsonb) from public.driver_documents x where x.driver_id = p.id)
      ) order by p.created_at desc), '[]'::jsonb) from public.profiles p where p.role = 'driver')
  );
end $$;

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

create or replace function public.admin_set_password(p_token text, p_user_id uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  if length(coalesce(p_password, '')) < 5 or length(p_password) > 72 then raise exception 'La contraseña debe tener entre 5 y 72 caracteres.'; end if;
  update public.profiles set password_hash = crypt(p_password, gen_salt('bf', 10)) where id = p_user_id;
  if not found then raise exception 'Usuario no encontrado.'; end if;
  delete from public.app_sessions where user_id = p_user_id;
end $$;

-- 9) Permisos: solo estas funciones son accesibles desde la app -------------------------------------
revoke all on function
  public.app_register(text,text,text,text), public.app_login(text,text), public.app_me(text), public.app_logout(text),
  public.ride_create(text,text,double precision,double precision,text), public.my_rides(text), public.cancel_my_ride(text,uuid),
  public.driver_set_location(text,double precision,double precision,boolean), public.driver_state(text),
  public.available_ride_requests(text), public.accept_ride(text,uuid), public.update_driver_ride_status(text,uuid,text),
  public.admin_dashboard(text), public.admin_create_driver(text,text,text,text,text,text,text,text,text,jsonb),
  public.admin_set_password(text,uuid,text)
from public;
grant execute on function
  public.app_register(text,text,text,text), public.app_login(text,text), public.app_me(text), public.app_logout(text),
  public.ride_create(text,text,double precision,double precision,text), public.my_rides(text), public.cancel_my_ride(text,uuid),
  public.driver_set_location(text,double precision,double precision,boolean), public.driver_state(text),
  public.available_ride_requests(text), public.accept_ride(text,uuid), public.update_driver_ride_status(text,uuid,text),
  public.admin_dashboard(text), public.admin_create_driver(text,text,text,text,text,text,text,text,text,jsonb),
  public.admin_set_password(text,uuid,text)
to anon, authenticated;

-- 10) Administrador inicial -------------------------------------------------------------------------
-- Opción A: regístrate en la app y luego ejecuta:
--   update public.profiles set role = 'admin' where email = 'TU_CORREO';
-- Opción B (cuenta ya existente sin contraseña, p. ej. creada con Supabase Auth): asígnale una nueva:
--   update public.profiles set password_hash = crypt('NUEVA_CONTRASEÑA_LARGA', gen_salt('bf', 10)) where email = 'TU_CORREO';

-- Taxi Cerca | Esquema inicial para Supabase
-- Ejecutar completo desde SQL Editor o con Supabase CLI.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text unique,
  phone text not null default '',
  role text not null default 'user' check (role in ('user','driver','admin')),
  created_at timestamptz not null default now()
);

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

create table if not exists public.driver_locations (
  driver_id uuid primary key references public.profiles(id) on delete cascade,
  lat double precision,
  lng double precision,
  is_online boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint driver_lat_range check (lat is null or lat between -90 and 90),
  constraint driver_lng_range check (lng is null or lng between -180 and 180)
);

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

create index if not exists rides_passenger_created_idx on public.rides(passenger_id, created_at desc);
create index if not exists rides_driver_status_idx on public.rides(driver_id, status);
create index if not exists rides_status_created_idx on public.rides(status, created_at);
create index if not exists driver_locations_online_idx on public.driver_locations(is_online) where is_online = true;
create index if not exists driver_documents_driver_idx on public.driver_documents(driver_id);

-- El rol se fija siempre como user al registrarse. Nunca se confía en metadata del navegador para asignar privilegios.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email, phone, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    new.email,
    coalesce(new.raw_user_meta_data->>'phone', ''),
    'user'
  )
  on conflict (id) do update set
    full_name = excluded.full_name,
    email = excluded.email,
    phone = excluded.phone;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'admin');
$$;

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

-- RPC segura: entrega solo solicitudes para las que este conductor es el más cercano.
create or replace function public.available_ride_requests()
returns table (
  id uuid,
  passenger_name text,
  passenger_phone text,
  pickup_label text,
  pickup_lat double precision,
  pickup_lng double precision,
  destination_label text,
  created_at timestamptz,
  distance_km double precision
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.profiles where profiles.id = auth.uid() and profiles.role = 'driver') then
    raise exception 'Solo los conductores pueden consultar solicitudes.';
  end if;
  if not exists (select 1 from public.driver_locations where driver_id = auth.uid() and is_online = true and lat is not null and lng is not null) then
    return;
  end if;
  return query
  with candidates as (
    select r.id as ride_id, p.full_name as p_name, p.phone as p_phone,
           r.pickup_label as p_label, r.pickup_lat as p_lat, r.pickup_lng as p_lng,
           r.destination_label as dest, r.created_at as created,
           dl.driver_id as candidate_driver,
           public.distance_km(dl.lat, dl.lng, r.pickup_lat, r.pickup_lng) as km,
           row_number() over (
             partition by r.id
             order by public.distance_km(dl.lat, dl.lng, r.pickup_lat, r.pickup_lng), dl.driver_id
           ) as proximity_rank
    from public.rides r
    join public.profiles p on p.id = r.passenger_id
    join public.driver_locations dl on dl.is_online = true and dl.lat is not null and dl.lng is not null
    join public.profiles dp on dp.id = dl.driver_id and dp.role = 'driver'
    where r.status = 'pending' and dl.updated_at > now() - interval '45 seconds'
  )
  select c.ride_id, c.p_name, c.p_phone, c.p_label, c.p_lat, c.p_lng, c.dest, c.created, c.km
  from candidates c
  where c.candidate_driver = auth.uid() and c.proximity_rank = 1 and c.km <= 20
  order by c.created asc;
end;
$$;

-- Revalida cercanía al aceptar y bloquea la solicitud para impedir asignaciones dobles.
create or replace function public.accept_ride(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ride public.rides%rowtype;
  v_nearest uuid;
  v_location public.driver_locations%rowtype;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'driver') then
    raise exception 'Solo un conductor puede aceptar viajes.';
  end if;
  select * into v_ride from public.rides where id = p_ride_id for update;
  if not found or v_ride.status <> 'pending' then raise exception 'Esta solicitud ya no está disponible.'; end if;
  select * into v_location from public.driver_locations where driver_id = auth.uid() and is_online = true and lat is not null and lng is not null;
  if not found then raise exception 'Conéctate y comparte tu ubicación para aceptar.'; end if;
  select dl.driver_id into v_nearest
  from public.driver_locations dl
  join public.profiles p on p.id = dl.driver_id and p.role = 'driver'
  where dl.is_online = true and dl.lat is not null and dl.lng is not null
    and dl.updated_at > now() - interval '45 seconds'
  order by public.distance_km(dl.lat, dl.lng, v_ride.pickup_lat, v_ride.pickup_lng), dl.driver_id
  limit 1;
  if v_nearest is distinct from auth.uid() then raise exception 'Otro conductor está más cerca de este pasajero.'; end if;
  if public.distance_km(v_location.lat, v_location.lng, v_ride.pickup_lat, v_ride.pickup_lng) > 20 then raise exception 'El viaje está fuera del radio de servicio.'; end if;
  update public.rides set driver_id = auth.uid(), status = 'accepted', accepted_at = now() where id = p_ride_id and status = 'pending';
  if not found then raise exception 'La solicitud fue tomada por otro conductor.'; end if;
end;
$$;

create or replace function public.update_driver_ride_status(p_ride_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status not in ('in_progress','completed') then raise exception 'Estado no permitido.'; end if;
  update public.rides
  set status = p_status,
      completed_at = case when p_status = 'completed' then now() else completed_at end
  where id = p_ride_id and driver_id = auth.uid()
    and ((status = 'accepted' and p_status = 'in_progress') or (status = 'in_progress' and p_status = 'completed'));
  if not found then raise exception 'No puedes cambiar el estado de este servicio.'; end if;
end;
$$;

create or replace function public.get_ride_driver(p_ride_id uuid)
returns table (
  driver_name text,
  driver_phone text,
  vehicle_make text,
  vehicle_model text,
  vehicle_color text,
  plate text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.rides
    where id = p_ride_id and passenger_id = auth.uid()
      and driver_id is not null and status in ('accepted','in_progress','completed')
  ) then
    raise exception 'No tienes acceso a los datos de este conductor.';
  end if;
  return query
  select p.full_name, p.phone, d.vehicle_make, d.vehicle_model, d.vehicle_color, d.plate
  from public.rides r
  join public.profiles p on p.id = r.driver_id
  left join public.driver_details d on d.driver_id = r.driver_id
  where r.id = p_ride_id and r.passenger_id = auth.uid();
end;
$$;

create or replace function public.cancel_my_ride(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.rides set status = 'cancelled'
  where id = p_ride_id and passenger_id = auth.uid() and status = 'pending';
  if not found then raise exception 'Solo puedes cancelar una solicitud que aún no ha sido aceptada.'; end if;
end;
$$;

-- RLS: políticas por tabla y permisos mínimos desde la API pública.
alter table public.profiles enable row level security;
alter table public.driver_details enable row level security;
alter table public.driver_documents enable row level security;
alter table public.driver_locations enable row level security;
alter table public.rides enable row level security;

revoke all on public.profiles, public.driver_details, public.driver_documents, public.driver_locations, public.rides from anon, authenticated;
grant select on public.profiles, public.driver_details, public.driver_documents, public.rides to authenticated;
grant select, insert, update on public.driver_locations to authenticated;

drop policy if exists "profile owner or admin reads profiles" on public.profiles;
create policy "profile owner or admin reads profiles" on public.profiles for select to authenticated using (id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "driver or admin reads driver details" on public.driver_details;
create policy "driver or admin reads driver details" on public.driver_details for select to authenticated using (driver_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "driver or admin reads documents" on public.driver_documents;
create policy "driver or admin reads documents" on public.driver_documents for select to authenticated using (driver_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "driver or admin reads locations" on public.driver_locations;
create policy "driver or admin reads locations" on public.driver_locations for select to authenticated using (driver_id = (select auth.uid()) or (select public.is_admin()));
drop policy if exists "driver inserts own location" on public.driver_locations;
create policy "driver inserts own location" on public.driver_locations for insert to authenticated with check (driver_id = (select auth.uid()) and exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'driver'));
drop policy if exists "driver updates own location" on public.driver_locations;
create policy "driver updates own location" on public.driver_locations for update to authenticated using (driver_id = (select auth.uid())) with check (driver_id = (select auth.uid()) and exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'driver'));

drop policy if exists "ride participants or admin read rides" on public.rides;
create policy "ride participants or admin read rides" on public.rides for select to authenticated using (passenger_id = (select auth.uid()) or driver_id = (select auth.uid()) or (select public.is_admin()));
drop policy if exists "passenger creates own ride" on public.rides;
create policy "passenger creates own ride" on public.rides for insert to authenticated with check (passenger_id = (select auth.uid()) and driver_id is null and status = 'pending' and exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'user'));

-- Las funciones RPC son el único camino para aceptar, cancelar o avanzar un viaje.
revoke all on function public.available_ride_requests() from public, anon;
revoke all on function public.accept_ride(uuid) from public, anon;
revoke all on function public.update_driver_ride_status(uuid,text) from public, anon;
revoke all on function public.cancel_my_ride(uuid) from public, anon;
revoke all on function public.get_ride_driver(uuid) from public, anon;
grant execute on function public.available_ride_requests() to authenticated;
grant execute on function public.accept_ride(uuid) to authenticated;
grant execute on function public.update_driver_ride_status(uuid,text) to authenticated;
grant execute on function public.cancel_my_ride(uuid) to authenticated;
grant execute on function public.get_ride_driver(uuid) to authenticated;
grant execute on function public.is_admin() to authenticated;

-- Habilita los eventos en tiempo real que consume la interfaz.
do $$
begin
  alter publication supabase_realtime add table public.rides;
exception when duplicate_object then null; when undefined_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null; when undefined_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.driver_documents;
exception when duplicate_object then null; when undefined_object then null;
end $$;

-- IMPORTANTE: después de ejecutar este archivo, promover manualmente el correo administrador:
-- update public.profiles set role = 'admin' where email = 'TU_CORREO_ADMIN';

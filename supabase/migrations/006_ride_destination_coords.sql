-- Taxi Cerca | Coordenadas de destino en los viajes.
-- Ejecutar completo en el SQL Editor de Supabase (después de 005).

alter table public.rides add column if not exists dest_lat double precision;
alter table public.rides add column if not exists dest_lng double precision;
alter table public.rides drop constraint if exists ride_dest_range;
alter table public.rides add constraint ride_dest_range check (
  (dest_lat is null and dest_lng is null) or
  (dest_lat is not null and dest_lng is not null and dest_lat between -90 and 90 and dest_lng between -180 and 180));

drop function if exists public.ride_create(text, text, double precision, double precision, text);

create or replace function public.ride_create(p_token text, p_label text, p_lat double precision, p_lng double precision, p_destination text,
  p_dest_lat double precision default null, p_dest_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['user']); v_ride public.rides%rowtype;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Ubicación de recogida no válida.'; end if;
  if (p_dest_lat is null) <> (p_dest_lng is null) or p_dest_lat not between -90 and 90 or p_dest_lng not between -180 and 180 then raise exception 'Coordenadas de destino no válidas.'; end if;
  if exists (select 1 from public.rides where passenger_id = v_me and status in ('pending','accepted','in_progress')) then
    raise exception 'Ya tienes un viaje activo.';
  end if;
  insert into public.rides(passenger_id, pickup_label, pickup_lat, pickup_lng, destination_label, dest_lat, dest_lng, status)
  values (v_me, left(coalesce(nullif(trim(p_label), ''), 'Ubicación actual'), 200), p_lat, p_lng,
          left(nullif(trim(coalesce(p_destination, '')), ''), 200), p_dest_lat, p_dest_lng, 'pending')
  returning * into v_ride;
  return to_jsonb(v_ride);
end $$;

-- Las solicitudes cercanas ahora incluyen las coordenadas de destino.
create or replace function public.available_ride_requests(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['driver']); v_out jsonb;
begin
  if not exists (select 1 from public.driver_locations where driver_id = v_me and is_online and lat is not null and lng is not null) then
    return '[]'::jsonb;
  end if;
  with candidates as (
    select r.id as ride_id, p.full_name as p_name, p.phone as p_phone, r.pickup_label, r.pickup_lat, r.pickup_lng,
           r.destination_label, r.dest_lat, r.dest_lng, r.created_at as created, dl.driver_id as cand,
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
    'destination_label', c.destination_label, 'dest_lat', c.dest_lat, 'dest_lng', c.dest_lng,
    'created_at', c.created, 'distance_km', c.km) order by c.created), '[]'::jsonb)
  into v_out from candidates c where c.cand = v_me and c.rnk = 1 and c.km <= 20;
  return v_out;
end $$;

revoke all on function public.ride_create(text,text,double precision,double precision,text,double precision,double precision), public.available_ride_requests(text) from public;
grant execute on function public.ride_create(text,text,double precision,double precision,text,double precision,double precision), public.available_ride_requests(text) to anon, authenticated;

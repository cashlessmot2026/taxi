-- Taxi Cerca | El valor a pagar siempre se calcula (km recorridos × valor por km) y queda guardado al finalizar.
-- Ejecutar completo en el SQL Editor de Supabase (después de 009).

-- Al finalizar:
--   * con tarifa de la plataforma activada -> mayor entre la tarifa mínima y (km × valor por km)
--   * sin ella -> el valor acordado por el conductor; si no hubo cotización -> la tarifa por kilómetros
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

-- El administrador también ve el valor por kilómetro con el que se calcula cada servicio.
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

revoke all on function public.update_driver_ride_status(text,uuid,text), public.admin_services(text) from public;
grant execute on function public.update_driver_ride_status(text,uuid,text), public.admin_services(text) to anon, authenticated;

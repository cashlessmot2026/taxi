-- Corrección: la política "passenger creates own ride" existía, pero faltaba el permiso INSERT,
-- por lo que solicitar un taxi fallaba con "permission denied for table rides".
grant insert (passenger_id, pickup_label, pickup_lat, pickup_lng, destination_label, status) on public.rides to authenticated;

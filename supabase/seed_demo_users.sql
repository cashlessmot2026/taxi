-- Taxis Teleclub | Usuarios DEMO (administrador, conductor y pasajero).
-- Se puede ejecutar varias veces: si el usuario ya existe, solo restablece su contraseña y lo habilita.
-- Requiere haber ejecutado antes las migraciones 003 a 009.
-- IMPORTANTE: son cuentas de prueba con contraseñas conocidas. Elimínalas o cámbiales la contraseña antes de operar con datos reales.

do $$
declare
  v_admin uuid; v_driver uuid; v_user uuid;
begin
  -- Administrador: usuario demo.admin / contraseña Demo12345
  select id into v_admin from public.profiles where lower(username) = 'demo.admin';
  if v_admin is null then
    insert into public.profiles(full_name, email, username, phone, role, password_hash, is_active)
    values ('Admin Demo', 'demo.admin@taxisteleclub.demo', 'demo.admin', '3000000001', 'admin', crypt('Demo12345', gen_salt('bf', 10)), true);
  else
    update public.profiles set role = 'admin', is_active = true, password_hash = crypt('Demo12345', gen_salt('bf', 10)) where id = v_admin;
  end if;

  -- Conductor: usuario demo.conductor / contraseña Demo12345
  select id into v_driver from public.profiles where lower(username) = 'demo.conductor';
  if v_driver is null then
    insert into public.profiles(full_name, email, username, phone, role, password_hash, is_active)
    values ('Conductor Demo', 'demo.conductor@taxisteleclub.demo', 'demo.conductor', '3000000002', 'driver', crypt('Demo12345', gen_salt('bf', 10)), true)
    returning id into v_driver;
  else
    update public.profiles set role = 'driver', is_active = true, password_hash = crypt('Demo12345', gen_salt('bf', 10)) where id = v_driver;
  end if;
  insert into public.driver_details(driver_id, vehicle_make, vehicle_model, vehicle_color, plate)
  values (v_driver, 'Chevrolet', 'Spark', 'Amarillo', 'DEMO123')
  on conflict (driver_id) do update set vehicle_make = excluded.vehicle_make, vehicle_model = excluded.vehicle_model,
    vehicle_color = excluded.vehicle_color, plate = excluded.plate, updated_at = now();

  -- Pasajero: usuario demo.pasajero / contraseña Demo12345
  select id into v_user from public.profiles where lower(username) = 'demo.pasajero';
  if v_user is null then
    insert into public.profiles(full_name, email, username, phone, role, password_hash, is_active)
    values ('Pasajero Demo', 'demo.pasajero@taxisteleclub.demo', 'demo.pasajero', '3000000003', 'user', crypt('Demo12345', gen_salt('bf', 10)), true);
  else
    update public.profiles set role = 'user', is_active = true, password_hash = crypt('Demo12345', gen_salt('bf', 10)) where id = v_user;
  end if;
end $$;

-- (Opcional) Tarifas de ejemplo para probar: sectores y valor por kilómetro.
insert into public.fare_sectors(name, min_fare) values ('Centro', 8000), ('Norte', 10000), ('Aeropuerto', 25000)
on conflict (lower(name)) do nothing;
update public.app_settings set value = '2500' where key = 'price_per_km' and value = '0';

-- Verificación: debe listar las 3 cuentas demo.
select username, role, is_active, email from public.profiles where username like 'demo.%' order by role;

-- Taxi Cerca | El administrador puede modificar conductores.
-- Ejecutar completo en el SQL Editor de Supabase (después de 004).

-- El panel ahora también recibe el nombre de usuario de cada conductor.
create or replace function public.admin_dashboard(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_me uuid := public._require_role(p_token, array['admin']);
begin
  return jsonb_build_object(
    'users_count', (select count(*) from public.profiles where role = 'user'),
    'rides_count', (select count(*) from public.rides),
    'drivers', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'username', p.username, 'phone', p.phone, 'created_at', p.created_at,
        'driver_details', (select to_jsonb(d) - 'driver_id' from public.driver_details d where d.driver_id = p.id),
        'driver_documents', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'drive_url', x.drive_url) order by x.created_at), '[]'::jsonb) from public.driver_documents x where x.driver_id = p.id)
      ) order by p.created_at desc), '[]'::jsonb) from public.profiles p where p.role = 'driver')
  );
end $$;

-- p_password vacío = no cambia la contraseña. p_docs reemplaza la lista de documentos.
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

revoke all on function public.admin_dashboard(text), public.admin_update_driver(text,uuid,text,text,text,text,text,text,text,text,text,jsonb) from public;
grant execute on function public.admin_dashboard(text), public.admin_update_driver(text,uuid,text,text,text,text,text,text,text,text,text,jsonb) to anon, authenticated;

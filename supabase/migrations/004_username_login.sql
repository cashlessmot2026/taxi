-- Taxi Cerca | Permite iniciar sesión con correo O nombre de usuario.
-- Ejecutar completo en el SQL Editor de Supabase (después de 003).

alter table public.profiles add column if not exists username text;
create unique index if not exists profiles_username_lower_idx on public.profiles (lower(username)) where username is not null;
-- El correo deja de ser obligatorio para cuentas que solo usan usuario (p. ej. el administrador).
alter table public.profiles alter column email drop not null;

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
  delete from public.login_attempts where email = v_key;
  return jsonb_build_object('token', public._new_session(v_user.id), 'profile', public._profile_json(v_user.id));
end $$;

revoke all on function public.app_login(text, text) from public;
grant execute on function public.app_login(text, text) to anon, authenticated;

-- Crear / actualizar el administrador (cambia la contraseña antes de ejecutar):
-- Si ya tienes una cuenta con tu correo, conviértela:
--   update public.profiles set role = 'admin', username = 'admin',
--     password_hash = crypt('TU_CONTRASEÑA', gen_salt('bf', 10)) where email = 'TU_CORREO';
-- Si no tienes ninguna, créala solo con usuario:
--   insert into public.profiles(full_name, username, role, password_hash)
--   values ('Administrador', 'admin', 'admin', crypt('TU_CONTRASEÑA', gen_salt('bf', 10)));

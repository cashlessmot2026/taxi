# Taxi Cerca — PWA React + Supabase

Aplicación web progresiva para operación de taxis con tres roles: pasajero, conductor y administrador. La interfaz está en español y es adaptable a celular, tableta y escritorio.

## Funciones incluidas

- Registro e inicio de sesión por correo y contraseña con Supabase Auth. No se usan accesos OAuth de Google, Facebook u otros proveedores.
- El registro público siempre crea un perfil `user`; ningún campo del navegador puede convertir a alguien en conductor o administrador.
- Pasajeros crean solicitudes de taxi con su ubicación GPS, destino opcional, estado del servicio e historial; al asignarse, ven nombre, teléfono y datos del vehículo del conductor.
- Conductores activan su disponibilidad y comparten la ubicación actual mientras están conectados.
- La función `available_ride_requests()` muestra una solicitud únicamente al conductor disponible más cercano dentro de 20 km. `accept_ride()` vuelve a verificar y bloquea la fila del viaje antes de asignarlo.
- Conductores pueden iniciar y finalizar un servicio. Los pasajeros pueden cancelar una solicitud que aún no ha sido aceptada.
- Administradores crean cuentas de conductor, registran información del vehículo y asocian enlaces de Google Drive a los documentos. El conductor ve esos enlaces dentro de su perfil.
- Supabase Realtime actualiza el estado de los viajes y las vistas.
- Manifest, icono y service worker para instalación como PWA. El shell básico puede abrir sin conexión; las operaciones con Supabase requieren conexión a Internet.

## 1. Crear y configurar Supabase

1. Crea un proyecto en [Supabase](https://supabase.com/dashboard).
2. En **Authentication → Sign In / Providers**, habilita Email y contraseña. Deshabilita proveedores sociales/OAuth que no vayas a usar.
3. Define reglas de contraseña y confirmación de correo según la política de tu operación. Los conductores creados por un administrador se confirman en el servidor al crearse.
4. Abre **SQL Editor** y ejecuta todo el archivo `supabase/migrations/001_taxi_cerca.sql`.
5. Registra tu cuenta de administrador desde la pantalla pública de registro (o crea el usuario desde Authentication).
6. Confirma el correo si tu configuración lo exige y luego ejecuta en SQL Editor, cambiando el correo:

   ```sql
   update public.profiles
   set role = 'admin'
   where email = 'tu-correo-administrador@dominio.com';
   ```

   Haz esto únicamente para la cuenta que controlas. No hay un formulario público para crear administradores.

## 2. Desplegar la función segura para crear conductores

La creación de cuentas ajenas no debe realizarse desde React con privilegios administrativos. La función Edge comprueba que quien llama tenga una sesión válida y rol `admin`, y solo entonces usa la llave privilegiada del servidor.

Con [Supabase CLI](https://supabase.com/docs/guides/cli):

```bash
supabase login
supabase link --project-ref TU_PROJECT_REF
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=TU_SERVICE_ROLE_KEY
supabase functions deploy create-driver
```

La clave `service_role` se configura como secreto del proyecto/función y **nunca** va en `.env.local`, `index.html`, React ni en el repositorio. Mantén activada la validación JWT de la función (`supabase/config.toml`).

> La función utiliza las variables `SUPABASE_URL` y `SUPABASE_ANON_KEY` disponibles en el entorno Edge, además del secreto `SUPABASE_SERVICE_ROLE_KEY` que debes configurar.

## 3. Configurar React

Copia `.env.example` a `.env.local` y coloca los datos de **Project URL** y la **publishable/anon key** pública del proyecto:

```env
VITE_SUPABASE_URL=https://TU-PROYECTO.supabase.co
VITE_SUPABASE_ANON_KEY=TU_CLAVE_PUBLICA_ANON_O_PUBLISHABLE
```

La llave pública puede estar en el frontend porque RLS limita las operaciones y datos accesibles. No pongas secretos en variables `VITE_`.

Instala dependencias y levanta el entorno:

```bash
npm install
npm run dev
```

Para compilar:

```bash
npm run build
npm run preview
```

Publica el contenido de `dist/` en un hosting estático con HTTPS. HTTPS es necesario para instalación PWA y geolocalización (excepto localhost durante desarrollo).

## 4. Datos y privacidad

- `auth.users` (gestionado por Supabase Auth) almacena las credenciales y hashes de contraseña. La aplicación **no almacena contraseñas en texto plano** ni las guarda en `profiles`.
- `profiles` guarda nombre, correo, teléfono y rol.
- `driver_details` guarda información del taxi.
- `driver_documents` guarda el título y URL de Drive; el archivo en sí permanece en Google Drive. Configura los permisos de Drive con cuidado: un enlace accesible para cualquiera puede ser compartido fuera de la app.
- `driver_locations` almacena la última ubicación y disponibilidad del conductor.
- `rides` guarda origen, coordenadas, destino, estados, pasajero y conductor asignado.

## 5. Reglas de seguridad incluidas

- RLS está habilitado en todas las tablas del esquema público usadas por la app.
- Las políticas permiten a los pasajeros leer sus viajes, a los conductores leer sus viajes asignados y documentos propios, y al administrador consultar la operación.
- El alta de conductor solo se realiza en Edge Function con comprobación de rol.
- El alta pública siempre genera rol `user` desde un trigger de base de datos.
- Las RPC controlan aceptación, cancelación y transiciones de estado. El radio de asignación está en 20 km y la ubicación se considera activa solo si se actualizó en los últimos 45 segundos.
- El frontend solo contiene la URL y llave pública de Supabase; no contiene credenciales de servidor.

**Importante:** ningún software puede garantizar que una aplicación sea imposible de vulnerar. Antes de operar con pasajeros reales, revisa las políticas RLS con pruebas en un proyecto de staging, exige contraseñas robustas y MFA para administradores, limita el acceso a documentos de Drive, configura alertas y copias de seguridad, y realiza una auditoría de seguridad. Esta entrega es una base funcional que requiere conectar y probar tu proyecto Supabase real.

## 6. Alcance / siguientes integraciones

Esta primera versión incluye solicitud y asignación de taxis por cercanía, pero no incluye aún mapa visual en vivo, rutas/ETA, tarifas dinámicas, recaudo/pagos, chat, notificaciones push, módulo de soporte ni verificación automática de documentos. Se pueden agregar como siguientes módulos. La geolocalización requiere permiso del usuario y HTTPS.

-- =====================================================================================================
-- Taxis Teleclub | TARIFAS MÍNIMAS DE TAXI POR CIUDAD (Colombia) — vigencia 2026
-- Ejecutar en el SQL Editor de Supabase (requiere la migración 009 o el schema.sql). Se puede repetir:
-- si el sector ya existe, actualiza su tarifa mínima.
--
-- MARCO NORMATIVO
--   En Colombia la tarifa del taxi la fija CADA autoridad de transporte local (alcaldía / secretaría de movilidad /
--   área metropolitana) mediante decreto o resolución, normalmente cada año, siguiendo la metodología nacional del
--   Ministerio de Transporte (Resolución 4350 de 1998, citada por la Secretaría de Movilidad de Cali) y el Decreto
--   Único Reglamentario del Sector Transporte (Decreto 1079 de 2015). No existe una tarifa nacional única, y hay
--   más de 1.100 municipios: aquí solo están las ciudades cuya tarifa 2026 se pudo verificar en fuentes públicas.
--
-- LO QUE ESTÁ CARGADO ES LA "CARRERA MÍNIMA" (valor mínimo a cobrar por servicio). El banderazo, el valor de la
-- unidad/caída y los recargos (nocturno, festivo, aeropuerto) NO se cargan: la app usa un único valor por km.
--
-- IMPORTANTE: son valores tomados de prensa y sitios oficiales a octubre de 2026. Confírmalos con el decreto de cada
-- ciudad antes de cobrar y vuelve a ejecutar este archivo cuando cambien. Puedes editarlos en el panel Tarifas.
--
-- NO VERIFICADO (sin cifra 2026 confiable en las fuentes consultadas; agrégalos desde el panel Tarifas cuando los
-- confirmes): Barranquilla (AMB; último dato público 2021: $6.300), Cúcuta, Pereira, Manizales, Armenia,
-- Villavicencio, Pasto, Neiva, Montería, Popayán, Valledupar, Sincelejo, Itagüí, Envigado, Soacha y los demás municipios.
-- =====================================================================================================

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

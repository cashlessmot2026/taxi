import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Debes iniciar sesión.' }, 401);

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!serviceKey) return json({ error: 'Falta configurar SUPABASE_SERVICE_ROLE_KEY en el servidor.' }, 500);

  const callerClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false, autoRefreshToken: false } });
  const token = authHeader.slice('Bearer '.length);
  const { data: authData, error: authError } = await callerClient.auth.getUser(token);
  if (authError || !authData.user) return json({ error: 'Sesión inválida o vencida.' }, 401);

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: callerProfile, error: profileError } = await admin.from('profiles').select('role').eq('id', authData.user.id).single();
  if (profileError || callerProfile?.role !== 'admin') return json({ error: 'No tienes permisos para crear conductores.' }, 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: 'El contenido enviado no es válido.' }, 400); }
  const fullName = String(body.full_name ?? '').trim();
  const email = String(body.email ?? '').trim().toLowerCase();
  const phone = String(body.phone ?? '').trim();
  const password = String(body.password ?? '');
  const vehicle = {
    vehicle_make: String(body.vehicle_make ?? '').trim(),
    vehicle_model: String(body.vehicle_model ?? '').trim(),
    vehicle_color: String(body.vehicle_color ?? '').trim(),
    plate: String(body.plate ?? '').trim().toUpperCase(),
  };
  const docs = Array.isArray(body.documents) ? body.documents as Array<{ title?: string; drive_url?: string }> : [];
  if (!fullName || !email || !phone || password.length < 10) return json({ error: 'Completa nombre, correo, teléfono y una contraseña de al menos 10 caracteres.' }, 400);
  if (docs.length > 10) return json({ error: 'Puedes asociar máximo 10 documentos.' }, 400);
  for (const doc of docs) {
    try {
      const u = new URL(String(doc.drive_url ?? ''));
      if (u.protocol !== 'https:' || !['drive.google.com', 'docs.google.com'].includes(u.hostname)) throw new Error('url');
      if (!String(doc.title ?? '').trim()) throw new Error('title');
    } catch { return json({ error: 'Cada documento debe tener un nombre y un enlace HTTPS de Google Drive o Google Docs.' }, 400); }
  }

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { full_name: fullName, phone },
  });
  if (createError || !created.user) return json({ error: createError?.message ?? 'No se pudo crear la cuenta.' }, 400);
  const driverId = created.user.id;

  const { error: upsertProfileError } = await admin.from('profiles').upsert({ id: driverId, full_name: fullName, email, phone, role: 'driver' });
  if (upsertProfileError) {
    await admin.auth.admin.deleteUser(driverId);
    return json({ error: `No se pudo guardar el perfil: ${upsertProfileError.message}` }, 500);
  }
  const { error: detailsError } = await admin.from('driver_details').upsert({ driver_id: driverId, ...vehicle });
  if (detailsError) {
    await admin.auth.admin.deleteUser(driverId);
    return json({ error: `No se pudo guardar el vehículo: ${detailsError.message}` }, 500);
  }
  if (docs.length) {
    const { error: docsError } = await admin.from('driver_documents').insert(docs.map((d) => ({ driver_id: driverId, title: String(d.title).trim(), drive_url: String(d.drive_url).trim(), created_by: authData.user.id })));
    if (docsError) {
      await admin.auth.admin.deleteUser(driverId);
      return json({ error: `No se pudieron guardar los documentos: ${docsError.message}` }, 500);
    }
  }
  return json({ ok: true, driver_id: driverId });
});

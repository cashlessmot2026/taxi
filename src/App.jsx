import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  ArrowRight, BadgeCheck, CarFront, Check, CheckCircle2, ChevronRight, CircleHelp,
  Clock3, FileText, Gauge, KeyRound, LogOut, MapPin, Menu, Navigation, Phone,
  Plus, Power, ShieldCheck, ShieldAlert, Smartphone, Sparkles, UserRound, Users,
  Wallet, X, Zap
} from 'lucide-react';
import { isSupabaseConfigured, supabase } from './supabase';

const statusLabel = { pending: 'Buscando conductor', accepted: 'Conductor asignado', in_progress: 'En camino', completed: 'Servicio finalizado', cancelled: 'Cancelado' };
const money = (value) => new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', maximumFractionDigits: 0 }).format(value || 0);

function Brand({ compact = false }) {
  return <div className={`brand ${compact ? 'brand-compact' : ''}`}><img className="brand-logo" src={`${import.meta.env.BASE_URL}logo.png`} alt="Taxis Teleclub"/><span>Taxis<span className="brand-light"> Teleclub</span></span></div>;
}

function ConfigNotice() {
  return <div className="config-screen"><div className="config-card"><Brand/><span className="eyebrow">CONFIGURACIÓN INICIAL</span><h1>Conecta tu proyecto Supabase</h1><p>La aplicación ya está preparada. Para activar registros, acceso, conductores y viajes, agrega las credenciales públicas de tu proyecto en <code>.env.local</code>.</p><div className="code-panel"><div>VITE_SUPABASE_URL=https://tu-proyecto.supabase.co</div><div>VITE_SUPABASE_ANON_KEY=tu-clave-publica</div></div><p className="small-muted">No coloques aquí la clave <b>service_role</b> ni ninguna clave secreta. El panel de administración y la creación de conductores se protegen en el servidor.</p><a className="text-link" href="https://supabase.com/dashboard" target="_blank" rel="noreferrer">Abrir Supabase <ArrowRight size={15}/></a></div></div>;
}

function AuthScreen() {
  const [mode, setMode] = useState('login');
  const [form, setForm] = useState({ name: '', phone: '', email: '', password: '' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const change = (key) => (e) => setForm((f) => ({ ...f, [key]: e.target.value }));
  async function submit(e) {
    e.preventDefault(); setError(''); setNotice(''); setBusy(true);
    try {
      if (mode === 'register') {
        if (form.password.length < 10) throw new Error('Usa una contraseña de al menos 10 caracteres.');
        const { data, error: err } = await supabase.auth.signUp({ email: form.email.trim(), password: form.password, options: { data: { full_name: form.name.trim(), phone: form.phone.trim() } } });
        if (err) throw err;
        if (!data.session) setNotice('Cuenta creada. Revisa tu correo para confirmar la dirección antes de iniciar sesión.');
      } else {
        const { error: err } = await supabase.auth.signInWithPassword({ email: form.email.trim(), password: form.password });
        if (err) throw err;
      }
    } catch (err) { setError(err.message || 'No fue posible completar la operación.'); }
    finally { setBusy(false); }
  }
  return <div className="auth-layout"><div className="auth-visual"><div className="visual-orb orb-one"/><div className="visual-orb orb-two"/><div className="visual-content"><Brand/><span className="eyebrow light">TU CIUDAD, A UN VIAJE</span><h1>Muévete fácil.<br/><em>Llega tranquilo.</em></h1><p>Una forma sencilla y cercana de pedir tu taxi, conectar con conductores y viajar con confianza.</p><div className="visual-stats"><div><strong>01</strong><span>Solicita</span></div><i/><div><strong>02</strong><span>Conecta</span></div><i/><div><strong>03</strong><span>Viaja</span></div></div><div className="visual-car"><div className="road"/><div className="car-illustration"><CarFront size={96}/></div><span className="route-dot dot-a"/><span className="route-dot dot-b"/><span className="route-line"/></div></div><span className="visual-foot">TAXI CERCA · MOVILIDAD LOCAL</span></div>
    <div className="auth-panel"><div className="auth-top"><span className="mobile-brand"><Brand compact/></span><span className="secure-note"><ShieldCheck size={15}/> Acceso seguro</span></div><div className="auth-form-wrap"><span className="eyebrow">{mode === 'login' ? 'QUÉ BUENO TENERTE DE VUELTA' : 'EMPIEZA A MOVERTE'}</span><h2>{mode === 'login' ? 'Bienvenido de nuevo' : 'Crea tu cuenta'}</h2><p className="form-sub">{mode === 'login' ? 'Ingresa tus datos para continuar.' : 'Regístrate para solicitar taxis de forma fácil.'}</p>
      <form onSubmit={submit} className="form-stack">
        {mode === 'register' && <><label>Nombre completo<input required autoComplete="name" value={form.name} onChange={change('name')} placeholder="Tu nombre y apellido"/></label><label>Teléfono<input required autoComplete="tel" value={form.phone} onChange={change('phone')} placeholder="300 000 0000"/></label></>}
        <label>Correo electrónico<input required type="email" autoComplete="email" value={form.email} onChange={change('email')} placeholder="nombre@correo.com"/></label>
        <label>Contraseña<input required type="password" autoComplete={mode === 'login' ? 'current-password' : 'new-password'} value={form.password} onChange={change('password')} placeholder="Mínimo 10 caracteres" minLength={10}/></label>
        {error && <div className="alert error">{error}</div>}{notice && <div className="alert success">{notice}</div>}
        <button className="btn btn-primary btn-full" disabled={busy}>{busy ? 'Procesando…' : mode === 'login' ? 'Ingresar' : 'Crear cuenta'} <ArrowRight size={17}/></button>
      </form><div className="auth-switch">{mode === 'login' ? '¿Todavía no tienes cuenta?' : '¿Ya tienes una cuenta?'} <button onClick={() => { setMode(mode === 'login' ? 'register' : 'login'); setError(''); setNotice(''); }}> {mode === 'login' ? 'Regístrate' : 'Inicia sesión'}</button></div><div className="auth-legal"><ShieldCheck size={15}/> Tus datos se protegen con autenticación y permisos en la base de datos.</div></div><div className="auth-bottom">© {new Date().getFullYear()} Taxi Cerca <span>·</span> Movilidad con confianza</div></div></div>;
}

function Shell({ profile, role, onSignOut, children, active = 'Inicio' }) {
  const [menu, setMenu] = useState(false);
  const nav = role === 'admin' ? [{ label: 'Panel', icon: Gauge }, { label: 'Conductores', icon: Users }] : role === 'driver' ? [{ label: 'Panel', icon: Gauge }, { label: 'Mis documentos', icon: FileText }] : [{ label: 'Inicio', icon: Navigation }, { label: 'Mis viajes', icon: Clock3 }];
  return <div className="app-shell"><aside className={`sidebar ${menu ? 'sidebar-open' : ''}`}><div className="side-brand"><Brand/></div><div className="side-caption">MENÚ PRINCIPAL</div><nav>{nav.map(({label, icon: Icon}) => <div className={`nav-item ${active === label ? 'nav-active' : ''}`} key={label}><Icon size={18}/>{label}{active === label && <span className="nav-indicator"/>}</div>)}</nav><div className="side-bottom"><div className="help-card"><span className="help-icon"><CircleHelp size={18}/></span><b>¿Necesitas ayuda?</b><p>Estamos para acompañarte.</p><a href="mailto:soporte@taxicerca.app">Contactar soporte <ArrowRight size={13}/></a></div><div className="side-profile"><div className="avatar">{(profile?.full_name || 'U').slice(0,1).toUpperCase()}</div><div className="profile-meta"><b>{profile?.full_name || 'Mi cuenta'}</b><span>{role === 'admin' ? 'Administrador' : role === 'driver' ? 'Conductor' : 'Pasajero'}</span></div><button className="icon-button" title="Cerrar sesión" onClick={onSignOut}><LogOut size={17}/></button></div></div></aside><main className="main-area"><header className="topbar"><button className="icon-button mobile-menu" onClick={() => setMenu(!menu)}><Menu size={21}/></button><div className="breadcrumb">Taxi Cerca <ChevronRight size={14}/><b>{active}</b></div><div className="top-right"><span className="online-pill"><i/> Sistema activo</span><div className="top-avatar">{(profile?.full_name || 'U').slice(0,1).toUpperCase()}</div></div></header><div className="page-content">{children}</div></main>{menu && <button className="menu-scrim" onClick={() => setMenu(false)} aria-label="Cerrar menú"/>}</div>;
}

function SectionTitle({ kicker, title, subtitle, action }) { return <div className="section-title"><div><span className="eyebrow">{kicker}</span><h1>{title}</h1>{subtitle && <p>{subtitle}</p>}</div>{action}</div>; }
function EmptyState({ icon: Icon = CarFront, title, text }) { return <div className="empty-state"><span><Icon size={24}/></span><b>{title}</b><p>{text}</p></div>; }

function UserDashboard({ profile }) {
  const [pickup, setPickup] = useState('Mi ubicación actual');
  const [destination, setDestination] = useState('');
  const [coords, setCoords] = useState(null);
  const [ride, setRide] = useState(null);
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const fetchRides = useCallback(async () => {
    const { data } = await supabase.from('rides').select('id,pickup_label,destination_label,status,created_at,driver_id').eq('passenger_id', profile.id).order('created_at', { ascending: false }).limit(10);
    if (data) {
      setHistory(data);
      const active = data.find((r) => ['pending','accepted','in_progress'].includes(r.status)) || null;
      if (active?.driver_id) {
        const { data: driverRows } = await supabase.rpc('get_ride_driver', { p_ride_id: active.id });
        setRide({ ...active, driver_info: driverRows?.[0] || null });
      } else setRide(active);
    }
  }, [profile.id]);
  useEffect(() => { fetchRides(); const ch = supabase.channel(`passenger-${profile.id}`).on('postgres_changes', { event: '*', schema: 'public', table: 'rides', filter: `passenger_id=eq.${profile.id}` }, fetchRides).subscribe(); return () => supabase.removeChannel(ch); }, [profile.id, fetchRides]);
  function locate() { setError(''); if (!navigator.geolocation) return setError('Tu navegador no permite obtener la ubicación.'); navigator.geolocation.getCurrentPosition((p) => setCoords({ lat: p.coords.latitude, lng: p.coords.longitude }), () => setError('Activa el permiso de ubicación para solicitar un taxi.'), { enableHighAccuracy: true, timeout: 12000 }); }
  async function requestRide(e) {
    e.preventDefault(); setError(''); if (!coords) return setError('Primero comparte tu ubicación actual.'); if (ride) return setError('Ya tienes un viaje activo.'); setLoading(true);
    const { data, error: err } = await supabase.from('rides').insert({ passenger_id: profile.id, pickup_label: pickup.trim() || 'Ubicación actual', pickup_lat: coords.lat, pickup_lng: coords.lng, destination_label: destination.trim() || null, status: 'pending' }).select().single();
    if (err) setError(err.message); else { setRide(data); setHistory((h) => [data, ...h]); }
    setLoading(false);
  }
  async function cancelRide() { if (!ride) return; const { error: err } = await supabase.rpc('cancel_my_ride', { p_ride_id: ride.id }); if (err) setError(err.message); else fetchRides(); }
  const past = history.filter((r) => !['pending','accepted','in_progress'].includes(r.status));
  return <><SectionTitle kicker="PANEL DEL PASAJERO" title={`Hola, ${(profile.full_name || '').split(' ')[0] || 'bienvenido'} 👋`} subtitle="Pide tu taxi en pocos pasos y sigue el estado de tu servicio."/><div className="user-grid"><div className="request-card"><div className="request-heading"><div><span className="eyebrow">NUEVO SERVICIO</span><h2>¿A dónde vamos hoy?</h2><p>Comparte tu ubicación y conecta con el taxi más cercano.</p></div><span className="request-icon"><CarFront size={24}/></span></div><form onSubmit={requestRide} className="ride-form"><label className="location-field"><span className="location-pin green-pin"><MapPin size={18}/></span><span className="field-content"><small>RECOGIDA</small><input value={pickup} onChange={(e) => setPickup(e.target.value)} placeholder="Punto de recogida"/></span><button type="button" className="locate-btn" onClick={locate} title="Usar ubicación actual"><Navigation size={17}/></button></label><div className="location-connector"/><label className="location-field"><span className="location-pin red-pin"><MapPin size={18}/></span><span className="field-content"><small>DESTINO (OPCIONAL)</small><input value={destination} onChange={(e) => setDestination(e.target.value)} placeholder="¿A dónde te llevamos?"/></span></label><div className="location-hint">{coords ? <><CheckCircle2 size={14}/> Ubicación detectada</> : <><MapPin size={14}/> Pulsa el botón de ubicación para continuar</>}</div>{error && <div className="alert error">{error}</div>}<button className="btn btn-dark btn-full request-submit" disabled={loading || !!ride}>{loading ? 'Solicitando…' : ride ? 'Ya tienes un viaje activo' : 'Solicitar taxi'} <ArrowRight size={17}/></button></form></div><div className="side-stack"><div className="safety-card"><span className="safety-icon"><ShieldCheck size={22}/></span><h3>Viaja con tranquilidad</h3><p>Los conductores son registrados por la administración y sus documentos quedan asociados a su perfil.</p><div className="safety-foot"><BadgeCheck size={15}/> Conductores verificados por administración</div></div><div className="tip-card"><Sparkles size={18}/><div><b>Un viaje más simple</b><p>Tu solicitud se muestra primero al conductor disponible más cercano.</p></div></div></div></div>
    {ride && <section className="content-card active-trip"><div className="card-heading"><div><span className="eyebrow">VIAJE ACTUAL</span><h2>Tu taxi está en proceso</h2></div><span className={`status-chip status-${ride.status}`}>{statusLabel[ride.status]}</span></div><div className="trip-route"><span className="route-icon"><MapPin size={17}/></span><div><small>RECOGIDA</small><b>{ride.pickup_label}</b></div><span className="route-arrow"><ArrowRight size={17}/></span><div><small>DESTINO</small><b>{ride.destination_label || 'Por definir'}</b></div></div>{ride.driver_info && <div className="assigned-driver"><span className="assigned-avatar"><CarFront size={18}/></span><div><b>{ride.driver_info.driver_name}</b><small>{[ride.driver_info.vehicle_make, ride.driver_info.vehicle_model, ride.driver_info.vehicle_color].filter(Boolean).join(' · ')} {ride.driver_info.plate ? `· ${ride.driver_info.plate}` : ''}</small></div>{ride.driver_info.driver_phone && <a href={`tel:${ride.driver_info.driver_phone}`}><Phone size={15}/> Llamar</a>}</div>}<div className="trip-bottom"><span>Solicitud #{ride.id.slice(0,8).toUpperCase()}</span>{ride.status === 'pending' && <button className="btn btn-outline btn-small" onClick={cancelRide}>Cancelar solicitud</button>}</div></section>}
    <section className="content-card history-card"><div className="card-heading"><div><span className="eyebrow">ACTIVIDAD RECIENTE</span><h2>Mis viajes</h2></div><span className="count-badge">{history.length} registros</span></div>{past.length ? <div className="history-list">{past.slice(0,5).map((r) => <div className="history-row" key={r.id}><span className="history-icon"><CarFront size={18}/></span><div className="history-info"><b>{r.destination_label || r.pickup_label}</b><small>{new Date(r.created_at).toLocaleString('es-CO')}</small></div><span className={`status-chip status-${r.status}`}>{statusLabel[r.status]}</span></div>)}</div> : <EmptyState title="Todavía no tienes viajes" text="Cuando solicites un taxi, aquí verás tu actividad."/>}</section></>;
}

function DriverDashboard({ profile }) {
  const [online, setOnline] = useState(false);
  const [location, setLocation] = useState(null);
  const [offers, setOffers] = useState([]);
  const [activeRide, setActiveRide] = useState(null);
  const [docs, setDocs] = useState([]);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState('');
  const refresh = useCallback(async () => {
    const [{ data: current }, { data: documents }, { data: pending }, { data: lastLocation }] = await Promise.all([
      supabase.from('rides').select('*').eq('driver_id', profile.id).in('status', ['accepted','in_progress']).order('created_at', { ascending: false }).limit(1).maybeSingle(),
      supabase.from('driver_documents').select('*').eq('driver_id', profile.id).order('created_at', { ascending: false }),
      supabase.rpc('available_ride_requests'),
      supabase.from('driver_locations').select('lat,lng,is_online,updated_at').eq('driver_id', profile.id).maybeSingle()
    ]);
    setActiveRide(current || null); setDocs(documents || []); setOffers(pending || []);
    const fresh = lastLocation?.is_online && lastLocation?.updated_at && (Date.now() - new Date(lastLocation.updated_at).getTime() < 45000);
    setOnline(Boolean(fresh));
    if (fresh && lastLocation.lat != null && lastLocation.lng != null) setLocation({ lat: lastLocation.lat, lng: lastLocation.lng });
  }, [profile.id]);
  async function updatePosition(coords, isOnline = online) { const point = { driver_id: profile.id, lat: coords.latitude, lng: coords.longitude, is_online: isOnline, updated_at: new Date().toISOString() }; const { error: err } = await supabase.from('driver_locations').upsert(point, { onConflict: 'driver_id' }); if (err) setError(err.message); else setLocation({ lat: coords.latitude, lng: coords.longitude }); }
  useEffect(() => { refresh(); const channel = supabase.channel(`driver-feed-${profile.id}`).on('postgres_changes', { event: '*', schema: 'public', table: 'rides' }, refresh).subscribe(); const timer = setInterval(refresh, 12000); return () => { clearInterval(timer); supabase.removeChannel(channel); }; }, [profile.id, refresh]);
  useEffect(() => { if (!online) return; if (!navigator.geolocation) { setError('Este dispositivo no permite ubicación.'); setOnline(false); return; } const watcher = navigator.geolocation.watchPosition((p) => updatePosition(p.coords, true), () => setError('No se pudo actualizar la ubicación. Revisa los permisos.'), { enableHighAccuracy: true, maximumAge: 10000 });
    const heartbeat = setInterval(() => navigator.geolocation.getCurrentPosition((p) => updatePosition(p.coords, true), () => {}, { enableHighAccuracy: true, maximumAge: 10000, timeout: 10000 }), 15000);
    return () => { navigator.geolocation.clearWatch(watcher); clearInterval(heartbeat); }; }, [online]);
  async function toggleOnline() { setError(''); if (online) { await supabase.from('driver_locations').upsert({ driver_id: profile.id, is_online: false, updated_at: new Date().toISOString() }, { onConflict: 'driver_id' }); setOnline(false); return; } if (!navigator.geolocation) return setError('Activa la ubicación en este dispositivo.'); navigator.geolocation.getCurrentPosition(async (p) => { await updatePosition(p.coords, true); setOnline(true); }, () => setError('Debes permitir el acceso a la ubicación para conectarte.'), { enableHighAccuracy: true, timeout: 12000 }); }
  async function accept(rideId) { setBusy(rideId); setError(''); const { error: err } = await supabase.rpc('accept_ride', { p_ride_id: rideId }); if (err) setError(err.message); else await refresh(); setBusy(''); }
  async function setRideStatus(next) { if (!activeRide) return; setBusy('status'); const { error: err } = await supabase.rpc('update_driver_ride_status', { p_ride_id: activeRide.id, p_status: next }); if (err) setError(err.message); else await refresh(); setBusy(''); }
  return <><SectionTitle kicker="PANEL DEL CONDUCTOR" title={`¡Hola, ${(profile.full_name || '').split(' ')[0] || 'conductor'}!`} subtitle="Conéctate para recibir solicitudes cercanas y gestionar tus servicios." action={<button className={`online-toggle ${online ? 'is-online' : ''}`} onClick={toggleOnline}><Power size={16}/>{online ? 'Estás conectado' : 'Conectarme'}</button>}/>{error && <div className="alert error page-alert">{error}</div>}<div className="driver-stats"><div className="metric-card"><span className="metric-icon yellow"><Navigation size={19}/></span><div><small>ESTADO</small><b>{online ? 'Disponible' : 'Desconectado'}</b></div><i className={online ? 'metric-live' : ''}/></div><div className="metric-card"><span className="metric-icon blue"><MapPin size={19}/></span><div><small>UBICACIÓN</small><b>{location ? 'Actualizada' : 'Sin ubicación'}</b></div></div><div className="metric-card"><span className="metric-icon purple"><CarFront size={19}/></span><div><small>SERVICIO ACTUAL</small><b>{activeRide ? 'En curso' : 'Ninguno'}</b></div></div></div>
    {activeRide && <section className="content-card active-trip"><div className="card-heading"><div><span className="eyebrow">SERVICIO ASIGNADO</span><h2>Viaje en curso</h2></div><span className={`status-chip status-${activeRide.status}`}>{statusLabel[activeRide.status]}</span></div><div className="trip-route"><span className="route-icon"><MapPin size={17}/></span><div><small>RECOGIDA</small><b>{activeRide.pickup_label}</b></div><span className="route-arrow"><ArrowRight size={17}/></span><div><small>DESTINO</small><b>{activeRide.destination_label || 'Por definir'}</b></div></div><div className="action-row">{activeRide.status === 'accepted' ? <button className="btn btn-primary" onClick={() => setRideStatus('in_progress')} disabled={busy === 'status'}>Iniciar viaje <ArrowRight size={16}/></button> : <button className="btn btn-primary" onClick={() => setRideStatus('completed')} disabled={busy === 'status'}>Finalizar servicio <Check size={16}/></button>}</div></section>}
    <section className="content-card offers-card"><div className="card-heading"><div><span className="eyebrow">SOLICITUDES CERCANAS</span><h2>Viajes disponibles</h2><p>Solo aparecen solicitudes donde eres el conductor disponible más cercano.</p></div><span className="count-badge">{offers.length} nuevas</span></div>{!online ? <EmptyState icon={Power} title="Conéctate para recibir viajes" text="Activa tu disponibilidad y permite el acceso a tu ubicación."/> : offers.length ? <div className="offer-list">{offers.map((r) => <div className="offer-row" key={r.id}><div className="offer-main"><span className="offer-icon"><CarFront size={20}/></span><div><b>{r.passenger_name || 'Pasajero'}</b><small><MapPin size={13}/> {r.pickup_label}</small><small><Navigation size={13}/> {r.destination_label || 'Destino por definir'}</small>{r.passenger_phone && <small><Phone size={12}/> {r.passenger_phone}</small>}</div></div><div className="offer-distance">{Number(r.distance_km).toFixed(1)} km</div><button className="btn btn-primary btn-small" onClick={() => accept(r.id)} disabled={!!busy || !!activeRide}>{busy === r.id ? 'Aceptando…' : 'Aceptar'}</button></div>)}</div> : <EmptyState title="No hay solicitudes cerca" text="Te avisaremos cuando haya un pasajero en tu zona."/>}</section>
    <section className="content-card docs-card"><div className="card-heading"><div><span className="eyebrow">PERFIL PROFESIONAL</span><h2>Mis documentos</h2></div><span className="count-badge">{docs.length} archivos</span></div>{docs.length ? <div className="documents-list">{docs.map((d) => <a href={d.drive_url} target="_blank" rel="noreferrer" key={d.id} className="document-row"><FileText size={18}/><span><b>{d.title}</b><small>Documento compartido por administración</small></span><ArrowRight size={16}/></a>)}</div> : <EmptyState icon={FileText} title="Aún no hay documentos" text="La administración agregará aquí los enlaces de tus documentos."/>}</section></>;
}

function AdminDashboard({ profile }) {
  const [drivers, setDrivers] = useState([]);
  const [usersCount, setUsersCount] = useState(0);
  const [ridesCount, setRidesCount] = useState(0);
  const [showForm, setShowForm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [form, setForm] = useState({ full_name: '', email: '', phone: '', password: '', vehicle_make: '', vehicle_model: '', vehicle_color: '', plate: '', documents: [{ title: 'Documento de identidad', url: '' }, { title: 'Licencia de conducción', url: '' }, { title: 'Documentos del vehículo', url: '' }] });
  const load = useCallback(async () => {
    const [{ data: list }, { count: users }, { count: rides }] = await Promise.all([
      supabase.from('profiles').select('id,full_name,email,phone,role,created_at,driver_details(vehicle_make,vehicle_model,vehicle_color,plate),driver_documents(id,title,drive_url)').eq('role', 'driver').order('created_at', { ascending: false }),
      supabase.from('profiles').select('*', { count: 'exact', head: true }).eq('role', 'user'),
      supabase.from('rides').select('*', { count: 'exact', head: true })
    ]); setDrivers(list || []); setUsersCount(users || 0); setRidesCount(rides || 0);
  }, []);
  useEffect(() => { load(); const c = supabase.channel('admin-refresh').on('postgres_changes', { event: '*', schema: 'public', table: 'profiles' }, load).on('postgres_changes', { event: '*', schema: 'public', table: 'driver_documents' }, load).subscribe(); return () => supabase.removeChannel(c); }, [load]);
  const setDoc = (index, key, value) => setForm((f) => ({ ...f, documents: f.documents.map((d, i) => i === index ? { ...d, [key]: value } : d) }));
  async function createDriver(e) {
    e.preventDefault(); setBusy(true); setError(''); setSuccess('');
    try {
      const docs = form.documents.filter((d) => d.url.trim()).map((d) => ({ title: d.title.trim(), drive_url: d.url.trim() }));
      const { data, error: err } = await supabase.functions.invoke('create-driver', { body: { ...form, documents: docs } });
      if (err) throw err; if (data?.error) throw new Error(data.error);
      setSuccess(`Conductor ${form.full_name} creado correctamente.`); setForm({ full_name: '', email: '', phone: '', password: '', vehicle_make: '', vehicle_model: '', vehicle_color: '', plate: '', documents: [{ title: 'Documento de identidad', url: '' }, { title: 'Licencia de conducción', url: '' }, { title: 'Documentos del vehículo', url: '' }] }); setShowForm(false); await load();
    } catch (err) { setError(err.message || 'No fue posible crear el conductor.'); }
    finally { setBusy(false); }
  }
  return <><SectionTitle kicker="CENTRO DE CONTROL" title="Administración" subtitle="Gestiona los conductores, sus documentos y la operación de Taxi Cerca." action={<button className="btn btn-primary" onClick={() => { setShowForm(!showForm); setError(''); setSuccess(''); }}><Plus size={17}/> Crear conductor</button>}/>{error && <div className="alert error page-alert">{error}</div>}{success && <div className="alert success page-alert">{success}</div>}<div className="admin-stats"><div className="admin-stat"><span className="stat-symbol stat-yellow"><Users size={20}/></span><div><small>PASAJEROS REGISTRADOS</small><strong>{usersCount}</strong><span>Usuarios en la plataforma</span></div></div><div className="admin-stat"><span className="stat-symbol stat-blue"><CarFront size={20}/></span><div><small>CONDUCTORES</small><strong>{drivers.length}</strong><span>Perfiles creados</span></div></div><div className="admin-stat"><span className="stat-symbol stat-purple"><Navigation size={20}/></span><div><small>SERVICIOS REGISTRADOS</small><strong>{ridesCount}</strong><span>Solicitudes de viaje</span></div></div></div>
    {showForm && <section className="content-card create-driver-card"><div className="card-heading"><div><span className="eyebrow">NUEVO PERFIL</span><h2>Registrar conductor</h2><p>La cuenta se crea con acceso de conductor y los documentos quedan asociados a su perfil.</p></div><button className="icon-button" onClick={() => setShowForm(false)}><X size={19}/></button></div><form onSubmit={createDriver} className="admin-form"><div className="form-section-label"><UserRound size={16}/> Datos personales y acceso</div><div className="field-grid"><label>Nombre completo<input required value={form.full_name} onChange={(e) => setForm({...form, full_name:e.target.value})} placeholder="Nombre del conductor"/></label><label>Teléfono<input required value={form.phone} onChange={(e) => setForm({...form, phone:e.target.value})} placeholder="300 000 0000"/></label><label>Correo de acceso<input required type="email" value={form.email} onChange={(e) => setForm({...form, email:e.target.value})} placeholder="conductor@correo.com"/></label><label>Contraseña temporal<input required type="password" minLength={10} value={form.password} onChange={(e) => setForm({...form, password:e.target.value})} placeholder="Mínimo 10 caracteres"/></label></div><div className="form-section-label"><CarFront size={16}/> Información del taxi</div><div className="field-grid three-fields"><label>Marca<input value={form.vehicle_make} onChange={(e) => setForm({...form, vehicle_make:e.target.value})} placeholder="Chevrolet"/></label><label>Modelo<input value={form.vehicle_model} onChange={(e) => setForm({...form, vehicle_model:e.target.value})} placeholder="Beat"/></label><label>Color<input value={form.vehicle_color} onChange={(e) => setForm({...form, vehicle_color:e.target.value})} placeholder="Amarillo"/></label><label>Placa<input value={form.plate} onChange={(e) => setForm({...form, plate:e.target.value.toUpperCase()})} placeholder="ABC123"/></label></div><div className="form-section-label"><FileText size={16}/> Documentos en Google Drive</div><p className="form-help">Pega enlaces compartidos que permitan la lectura al personal autorizado. No subas documentos directamente al código.</p><div className="documents-form">{form.documents.map((d, i) => <label key={i}>{d.title}<input type="url" value={d.url} onChange={(e) => setDoc(i, 'url', e.target.value)} placeholder="https://drive.google.com/file/d/…"/></label>)}</div><div className="form-actions"><button type="button" className="btn btn-outline" onClick={() => setShowForm(false)}>Cancelar</button><button className="btn btn-primary" disabled={busy}>{busy ? 'Creando perfil…' : 'Crear conductor'} <ArrowRight size={16}/></button></div></form></section>}
    <section className="content-card driver-management"><div className="card-heading"><div><span className="eyebrow">TU EQUIPO</span><h2>Conductores registrados</h2></div><span className="count-badge">{drivers.length} perfiles</span></div>{drivers.length ? <div className="driver-table-wrap"><table className="driver-table"><thead><tr><th>CONDUCTOR</th><th>VEHÍCULO</th><th>PLACA</th><th>DOCUMENTOS</th><th>REGISTRO</th></tr></thead><tbody>{drivers.map((d) => <tr key={d.id}><td><div className="table-person"><span className="avatar">{(d.full_name || 'C').slice(0,1).toUpperCase()}</span><span><b>{d.full_name}</b><small>{d.email || d.phone || 'Sin contacto'}</small></span></div></td><td>{[d.driver_details?.vehicle_make, d.driver_details?.vehicle_model].filter(Boolean).join(' ') || 'Sin datos'}<small className="table-sub">{d.driver_details?.vehicle_color || ''}</small></td><td><span className="plate-chip">{d.driver_details?.plate || '—'}</span></td><td><div className="doc-links">{(d.driver_documents || []).length ? d.driver_documents.map((doc) => <a href={doc.drive_url} target="_blank" rel="noreferrer" key={doc.id} title={doc.title}><FileText size={15}/></a>) : <span className="muted">Sin documentos</span>}</div></td><td>{new Date(d.created_at).toLocaleDateString('es-CO')}</td></tr>)}</tbody></table></div> : <EmptyState icon={Users} title="Aún no has creado conductores" text="Usa el botón Crear conductor para registrar el primer perfil."/>}</section></>;
}

export default function App() {
  const [session, setSession] = useState(null);
  const [profile, setProfile] = useState(null);
  const [loading, setLoading] = useState(true);
  const [profileError, setProfileError] = useState('');
  const loadProfile = useCallback(async (user) => {
    if (!user) { setProfile(null); return; }
    const { data, error } = await supabase.from('profiles').select('*').eq('id', user.id).maybeSingle();
    if (error) { setProfileError(error.message); setProfile(null); }
    else { setProfile(data); setProfileError(''); }
  }, []);
  useEffect(() => {
    if (!supabase) { setLoading(false); return; }
    supabase.auth.getSession().then(async ({ data }) => { setSession(data.session); await loadProfile(data.session?.user); setLoading(false); });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, next) => { setSession(next); setTimeout(() => loadProfile(next?.user), 0); });
    return () => listener.subscription.unsubscribe();
  }, [loadProfile]);
  async function signOut() { await supabase.auth.signOut(); setSession(null); setProfile(null); }
  if (!isSupabaseConfigured) return <ConfigNotice/>;
  if (loading || (session && !profile && !profileError)) return <div className="loading-screen"><div className="loader-mark"><CarFront size={26}/></div><span>Preparando tu experiencia…</span></div>;
  if (!session) return <AuthScreen/>;
  if (profileError || !profile) return <div className="loading-screen"><div className="error-state"><ShieldAlert size={30}/><h2>No se pudo cargar tu perfil</h2><p>{profileError || 'El usuario inició sesión, pero no tiene un perfil asociado. Contacta a administración.'}</p><button className="btn btn-outline" onClick={signOut}>Cerrar sesión</button></div></div>;
  const role = profile.role;
  return <Shell profile={profile} role={role} onSignOut={signOut} active={role === 'admin' ? 'Panel' : role === 'driver' ? 'Panel' : 'Inicio'}>{role === 'admin' ? <AdminDashboard profile={profile}/> : role === 'driver' ? <DriverDashboard profile={profile}/> : <UserDashboard profile={profile}/>}</Shell>;
}

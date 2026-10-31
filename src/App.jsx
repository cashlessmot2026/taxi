import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  ArrowRight, BadgeCheck, CarFront, Check, CheckCircle2, ChevronRight, CircleHelp,
  Clock3, FileText, Gauge, KeyRound, LogOut, MapPin, Menu, Navigation, Phone,
  Download, Pencil, Plus, Power, ShieldCheck, ShieldAlert, Smartphone, Sparkles, UserRound, Users,
  Wallet, X, Zap
} from 'lucide-react';
import { motion, animate } from 'motion/react';
import { isSupabaseConfigured } from './supabase';
import { rpc, setToken, getToken } from './api';

const statusLabel = { pending: 'Buscando conductor', accepted: 'Conductor asignado', in_progress: 'En camino', completed: 'Servicio finalizado', cancelled: 'Cancelado' };
const money = (value) => new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', maximumFractionDigits: 0 }).format(value || 0);

const fadeUp = { hidden: { opacity: 0, y: 18 }, show: { opacity: 1, y: 0, transition: { duration: 0.5, ease: [0.22, 1, 0.36, 1] } } };
const stagger = { hidden: {}, show: { transition: { staggerChildren: 0.08, delayChildren: 0.04 } } };
function Page({ children }) { return <motion.div variants={stagger} initial="hidden" animate="show">{children}</motion.div>; }
function CountUp({ value }) {
  const [n, setN] = useState(0);
  useEffect(() => { const c = animate(0, Number(value) || 0, { duration: 0.9, ease: 'easeOut', onUpdate: (v) => setN(Math.round(v)) }); return () => c.stop(); }, [value]);
  return <>{n}</>;
}

function Brand({ compact = false }) {
  return <div className={`brand ${compact ? 'brand-compact' : ''}`}><img className="brand-logo" src={`${import.meta.env.BASE_URL}logo.png`} alt="Taxis Teleclub"/><span>Taxis<span className="brand-light"> Teleclub</span></span></div>;
}

let deferredInstall = null;
if (typeof window !== 'undefined') {
  window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); deferredInstall = e; window.dispatchEvent(new Event('install-ready')); });
  window.addEventListener('appinstalled', () => { deferredInstall = null; window.dispatchEvent(new Event('install-ready')); });
}

function InstallButton({ className = '' }) {
  const [, force] = useState(0);
  const [help, setHelp] = useState(false);
  useEffect(() => { const f = () => force((n) => n + 1); window.addEventListener('install-ready', f); return () => window.removeEventListener('install-ready', f); }, []);
  const standalone = window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone;
  if (standalone) return null;
  const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
  async function install() {
    if (deferredInstall) { deferredInstall.prompt(); await deferredInstall.userChoice; deferredInstall = null; force((n) => n + 1); }
    else setHelp(true);
  }
  return <><button type="button" className={`btn btn-install ${className}`} onClick={install}><Download size={16}/> Descargar app</button>
    {help && <div className="install-help" role="dialog"><div className="install-card"><button className="icon-button install-close" onClick={() => setHelp(false)}><X size={18}/></button><img src={`${import.meta.env.BASE_URL}logo.png`} alt="" width="64" height="64"/><h3>Instala Taxis Teleclub</h3>{ios ? <p>En Safari pulsa el botón <b>Compartir</b> y luego <b>Añadir a pantalla de inicio</b>.</p> : <p>Abre el menú del navegador (⋮) y elige <b>Instalar aplicación</b> o <b>Añadir a pantalla de inicio</b>. Si no aparece, abre esta página en Chrome o Safari.</p>}</div></div>}</>;
}

const PORTALS = {
  '#/conductor': { role: 'driver', eyebrow: 'PORTAL DEL CONDUCTOR', title: 'Acceso conductores', sub: 'Ingresa con el correo y la contraseña que te entregó la administración.' },
  '#/admin': { role: 'admin', eyebrow: 'PORTAL DE ADMINISTRACIÓN', title: 'Acceso administración', sub: 'Solo para cuentas de administrador.' },
  '#/pasajero': { role: 'user', eyebrow: 'PORTAL DEL PASAJERO', title: 'Acceso pasajeros', sub: 'Ingresa tus datos para pedir tu taxi.' }
};
const ROLE_NAME = { driver: 'conductor', admin: 'administrador', user: 'pasajero' };
function usePortal() {
  const read = () => PORTALS[window.location.hash.replace(/\/$/, '').toLowerCase()] || null;
  const [portal, setPortal] = useState(read);
  useEffect(() => { const f = () => setPortal(read()); window.addEventListener('hashchange', f); return () => window.removeEventListener('hashchange', f); }, []);
  return portal;
}

function ConfigNotice() {
  return <div className="config-screen"><div className="config-card"><Brand/><span className="eyebrow">CONFIGURACIÓN INICIAL</span><h1>Conecta tu proyecto Supabase</h1><p>La aplicación ya está preparada. Para activar registros, acceso, conductores y viajes, agrega las credenciales públicas de tu proyecto en <code>.env.local</code>.</p><div className="code-panel"><div>VITE_SUPABASE_URL=https://tu-proyecto.supabase.co</div><div>VITE_SUPABASE_ANON_KEY=tu-clave-publica</div></div><p className="small-muted">No coloques aquí la clave <b>service_role</b> ni ninguna clave secreta. El panel de administración y la creación de conductores se protegen en el servidor.</p><a className="text-link" href="https://supabase.com/dashboard" target="_blank" rel="noreferrer">Abrir Supabase <ArrowRight size={15}/></a></div></div>;
}

function AuthScreen({ onAuth, portal }) {
  const canRegister = !portal || portal.role === 'user';
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
        if (form.password.length < 5) throw new Error('Usa una contraseña de al menos 5 caracteres.');
        const d = await rpc('app_register', { p_name: form.name.trim(), p_email: form.email.trim(), p_phone: form.phone.trim(), p_password: form.password }, { auth: false });
        setToken(d.token); onAuth(d.profile);
      } else {
        const d = await rpc('app_login', { p_email: form.email.trim(), p_password: form.password }, { auth: false });
        if (d?.error) throw new Error(d.error);
        setToken(d.token);
        if (portal && d.profile.role !== portal.role) {
          try { await rpc('app_logout'); } catch { /* sin sesión */ }
          setToken(null);
          throw new Error(`Esta cuenta no es de ${ROLE_NAME[portal.role]}. Usa el acceso que corresponde a tu cuenta.`);
        }
        onAuth(d.profile);
      }
    } catch (err) { setError(err.message || 'No fue posible completar la operación.'); }
    finally { setBusy(false); }
  }
  return <div className="auth-layout"><div className="auth-visual"><motion.div className="visual-orb orb-one" animate={{ y: [0, -22, 0], x: [0, 12, 0] }} transition={{ duration: 9, repeat: Infinity, ease: 'easeInOut' }}/><motion.div className="visual-orb orb-two" animate={{ y: [0, 18, 0], x: [0, -14, 0] }} transition={{ duration: 11, repeat: Infinity, ease: 'easeInOut' }}/><div className="visual-content"><Brand/><span className="eyebrow light">TU CIUDAD, A UN VIAJE</span><h1>Muévete fácil.<br/><em>Llega tranquilo.</em></h1><p>Una forma sencilla y cercana de pedir tu taxi, conectar con conductores y viajar con confianza.</p><div className="visual-stats"><div><strong>01</strong><span>Solicita</span></div><i/><div><strong>02</strong><span>Conecta</span></div><i/><div><strong>03</strong><span>Viaja</span></div></div><div className="visual-car"><div className="road"/><motion.div className="car-illustration" animate={{ x: [-6, 6, -6], rotate: [-1, 1, -1] }} transition={{ duration: 5, repeat: Infinity, ease: 'easeInOut' }}><CarFront size={96}/></motion.div><span className="route-dot dot-a"/><span className="route-dot dot-b"/><span className="route-line"/></div></div><span className="visual-foot">TAXI CERCA · MOVILIDAD LOCAL</span></div>
    <div className="auth-panel"><div className="auth-top"><span className="mobile-brand"><Brand compact/></span><span className="secure-note"><ShieldCheck size={15}/> Acceso seguro</span></div><div className="auth-form-wrap"><span className="eyebrow">{portal ? portal.eyebrow : mode === 'login' ? 'QUÉ BUENO TENERTE DE VUELTA' : 'EMPIEZA A MOVERTE'}</span><h2>{mode === 'login' ? (portal ? portal.title : 'Bienvenido de nuevo') : 'Crea tu cuenta'}</h2><p className="form-sub">{mode === 'login' ? (portal ? portal.sub : 'Ingresa tus datos para continuar.') : 'Regístrate para solicitar taxis de forma fácil.'}</p>
      <form onSubmit={submit} className="form-stack">
        {mode === 'register' && <><label>Nombre completo<input required autoComplete="name" value={form.name} onChange={change('name')} placeholder="Tu nombre y apellido"/></label><label>Teléfono<input required autoComplete="tel" value={form.phone} onChange={change('phone')} placeholder="300 000 0000"/></label></>}
        <label>{mode === 'login' ? 'Correo o usuario' : 'Correo electrónico'}<input required type={mode === 'login' ? 'text' : 'email'} autoComplete={mode === 'login' ? 'username' : 'email'} autoCapitalize="none" value={form.email} onChange={change('email')} placeholder={mode === 'login' ? 'Correo o nombre de usuario' : 'nombre@correo.com'}/></label>
        <label>Contraseña<input required type="password" autoComplete={mode === 'login' ? 'current-password' : 'new-password'} value={form.password} onChange={change('password')} placeholder="Mínimo 5 caracteres" minLength={5}/></label>
        {error && <div className="alert error">{error}</div>}{notice && <div className="alert success">{notice}</div>}
        <button className="btn btn-primary btn-full" disabled={busy}>{busy ? 'Procesando…' : mode === 'login' ? 'Ingresar' : 'Crear cuenta'} <ArrowRight size={17}/></button>
      </form>{canRegister && <div className="auth-switch">{mode === 'login' ? '¿Todavía no tienes cuenta?' : '¿Ya tienes una cuenta?'} <button onClick={() => { setMode(mode === 'login' ? 'register' : 'login'); setError(''); setNotice(''); }}> {mode === 'login' ? 'Regístrate' : 'Inicia sesión'}</button></div>}<div className="install-row"><InstallButton/></div><div className="auth-legal"><ShieldCheck size={15}/> Tus datos se protegen con autenticación y permisos en la base de datos.</div></div><div className="auth-bottom">© {new Date().getFullYear()} Taxi Cerca <span>·</span> Movilidad con confianza</div></div></div>;
}

function Shell({ profile, role, onSignOut, children, active = 'Inicio' }) {
  const [menu, setMenu] = useState(false);
  const nav = role === 'admin' ? [{ label: 'Panel', icon: Gauge }, { label: 'Conductores', icon: Users }] : role === 'driver' ? [{ label: 'Panel', icon: Gauge }, { label: 'Mis documentos', icon: FileText }] : [{ label: 'Inicio', icon: Navigation }, { label: 'Mis viajes', icon: Clock3 }];
  return <div className="app-shell"><aside className={`sidebar ${menu ? 'sidebar-open' : ''}`}><div className="side-brand"><Brand/></div><div className="side-caption">MENÚ PRINCIPAL</div><nav>{nav.map(({label, icon: Icon}) => <div className={`nav-item ${active === label ? 'nav-active' : ''}`} key={label}><Icon size={18}/>{label}{active === label && <motion.span layoutId="nav-ind" className="nav-indicator"/>}</div>)}</nav><div className="side-bottom"><div className="help-card"><span className="help-icon"><CircleHelp size={18}/></span><b>¿Necesitas ayuda?</b><p>Estamos para acompañarte.</p><a href="mailto:soporte@taxicerca.app">Contactar soporte <ArrowRight size={13}/></a></div><div className="side-profile"><div className="avatar">{(profile?.full_name || 'U').slice(0,1).toUpperCase()}</div><div className="profile-meta"><b>{profile?.full_name || 'Mi cuenta'}</b><span>{role === 'admin' ? 'Administrador' : role === 'driver' ? 'Conductor' : 'Pasajero'}</span></div><button className="icon-button" title="Cerrar sesión" onClick={onSignOut}><LogOut size={17}/></button></div></div></aside><main className="main-area"><header className="topbar"><button className="icon-button mobile-menu" onClick={() => setMenu(!menu)}><Menu size={21}/></button><div className="breadcrumb">Taxi Cerca <ChevronRight size={14}/><b>{active}</b></div><div className="top-right"><InstallButton className="btn-install-small"/><span className="online-pill"><i/> Sistema activo</span><div className="top-avatar">{(profile?.full_name || 'U').slice(0,1).toUpperCase()}</div></div></header><div className="page-content">{children}</div></main>{menu && <button className="menu-scrim" onClick={() => setMenu(false)} aria-label="Cerrar menú"/>}</div>;
}

function SectionTitle({ kicker, title, subtitle, action }) { return <motion.div variants={fadeUp} className="section-title"><div><span className="eyebrow">{kicker}</span><h1>{title}</h1>{subtitle && <p>{subtitle}</p>}</div>{action}</motion.div>; }
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
    try { const d = await rpc('my_rides'); setHistory(d.history || []); setRide(d.active || null); } catch { /* se reintenta en el siguiente ciclo */ }
  }, []);
  useEffect(() => { fetchRides(); const t = setInterval(fetchRides, 6000); return () => clearInterval(t); }, [fetchRides]);
  function locate() { setError(''); if (!navigator.geolocation) return setError('Tu navegador no permite obtener la ubicación.'); navigator.geolocation.getCurrentPosition((p) => setCoords({ lat: p.coords.latitude, lng: p.coords.longitude }), () => setError('Activa el permiso de ubicación para solicitar un taxi.'), { enableHighAccuracy: true, timeout: 12000 }); }
  async function requestRide(e) {
    e.preventDefault(); setError(''); if (!coords) return setError('Primero comparte tu ubicación actual.'); if (ride) return setError('Ya tienes un viaje activo.'); setLoading(true);
    try { await rpc('ride_create', { p_label: pickup.trim() || 'Ubicación actual', p_lat: coords.lat, p_lng: coords.lng, p_destination: destination.trim() || null }); await fetchRides(); }
    catch (err) { setError(err.message); }
    setLoading(false);
  }
  async function cancelRide() { if (!ride) return; try { await rpc('cancel_my_ride', { p_ride_id: ride.id }); fetchRides(); } catch (err) { setError(err.message); } }
  const past = history.filter((r) => !['pending','accepted','in_progress'].includes(r.status));
  return <Page><SectionTitle kicker="PANEL DEL PASAJERO" title={`Hola, ${(profile.full_name || '').split(' ')[0] || 'bienvenido'} 👋`} subtitle="Pide tu taxi en pocos pasos y sigue el estado de tu servicio."/><div className="user-grid"><div className="request-card"><div className="request-heading"><div><span className="eyebrow">NUEVO SERVICIO</span><h2>¿A dónde vamos hoy?</h2><p>Comparte tu ubicación y conecta con el taxi más cercano.</p></div><span className="request-icon"><CarFront size={24}/></span></div><form onSubmit={requestRide} className="ride-form"><label className="location-field"><span className="location-pin green-pin"><MapPin size={18}/></span><span className="field-content"><small>RECOGIDA</small><input value={pickup} onChange={(e) => setPickup(e.target.value)} placeholder="Punto de recogida"/></span><button type="button" className="locate-btn" onClick={locate} title="Usar ubicación actual"><Navigation size={17}/></button></label><div className="location-connector"/><label className="location-field"><span className="location-pin red-pin"><MapPin size={18}/></span><span className="field-content"><small>DESTINO (OPCIONAL)</small><input value={destination} onChange={(e) => setDestination(e.target.value)} placeholder="¿A dónde te llevamos?"/></span></label><div className="location-hint">{coords ? <><CheckCircle2 size={14}/> Ubicación detectada</> : <><MapPin size={14}/> Pulsa el botón de ubicación para continuar</>}</div>{error && <div className="alert error">{error}</div>}<button className="btn btn-dark btn-full request-submit" disabled={loading || !!ride}>{loading ? 'Solicitando…' : ride ? 'Ya tienes un viaje activo' : 'Solicitar taxi'} <ArrowRight size={17}/></button></form></div><div className="side-stack"><div className="safety-card"><span className="safety-icon"><ShieldCheck size={22}/></span><h3>Viaja con tranquilidad</h3><p>Los conductores son registrados por la administración y sus documentos quedan asociados a su perfil.</p><div className="safety-foot"><BadgeCheck size={15}/> Conductores verificados por administración</div></div><div className="tip-card"><Sparkles size={18}/><div><b>Un viaje más simple</b><p>Tu solicitud se muestra primero al conductor disponible más cercano.</p></div></div></div></div>
    {ride && <motion.section variants={fadeUp} className="content-card active-trip"><div className="card-heading"><div><span className="eyebrow">VIAJE ACTUAL</span><h2>Tu taxi está en proceso</h2></div><span className={`status-chip status-${ride.status}`}>{statusLabel[ride.status]}</span></div><div className="trip-route"><span className="route-icon"><MapPin size={17}/></span><div><small>RECOGIDA</small><b>{ride.pickup_label}</b></div><span className="route-arrow"><ArrowRight size={17}/></span><div><small>DESTINO</small><b>{ride.destination_label || 'Por definir'}</b></div></div>{ride.driver_info && <div className="assigned-driver"><span className="assigned-avatar"><CarFront size={18}/></span><div><b>{ride.driver_info.driver_name}</b><small>{[ride.driver_info.vehicle_make, ride.driver_info.vehicle_model, ride.driver_info.vehicle_color].filter(Boolean).join(' · ')} {ride.driver_info.plate ? `· ${ride.driver_info.plate}` : ''}</small></div>{ride.driver_info.driver_phone && <a href={`tel:${ride.driver_info.driver_phone}`}><Phone size={15}/> Llamar</a>}</div>}<div className="trip-bottom"><span>Solicitud #{ride.id.slice(0,8).toUpperCase()}</span>{ride.status === 'pending' && <button className="btn btn-outline btn-small" onClick={cancelRide}>Cancelar solicitud</button>}</div></motion.section>}
    <motion.section variants={fadeUp} className="content-card history-card"><div className="card-heading"><div><span className="eyebrow">ACTIVIDAD RECIENTE</span><h2>Mis viajes</h2></div><span className="count-badge">{history.length} registros</span></div>{past.length ? <div className="history-list">{past.slice(0,5).map((r) => <div className="history-row" key={r.id}><span className="history-icon"><CarFront size={18}/></span><div className="history-info"><b>{r.destination_label || r.pickup_label}</b><small>{new Date(r.created_at).toLocaleString('es-CO')}</small></div><span className={`status-chip status-${r.status}`}>{statusLabel[r.status]}</span></div>)}</div> : <EmptyState title="Todavía no tienes viajes" text="Cuando solicites un taxi, aquí verás tu actividad."/>}</motion.section></Page>;
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
    try {
      const [st, pending] = await Promise.all([rpc('driver_state'), rpc('available_ride_requests')]);
      setActiveRide(st.active_ride || null); setDocs(st.documents || []); setOffers(pending || []);
      const l = st.location;
      const fresh = Boolean(l?.is_online && l?.updated_at && (Date.now() - new Date(l.updated_at).getTime() < 45000));
      setOnline(fresh);
      if (fresh && l.lat != null && l.lng != null) setLocation({ lat: l.lat, lng: l.lng });
    } catch { /* se reintenta en el siguiente ciclo */ }
  }, []);
  async function updatePosition(coords, isOnline = online) { try { await rpc('driver_set_location', { p_lat: coords.latitude, p_lng: coords.longitude, p_online: isOnline }); setLocation({ lat: coords.latitude, lng: coords.longitude }); } catch (err) { setError(err.message); } }
  useEffect(() => { refresh(); const timer = setInterval(refresh, 6000); return () => clearInterval(timer); }, [refresh]);
  useEffect(() => { if (!online) return; if (!navigator.geolocation) { setError('Este dispositivo no permite ubicación.'); setOnline(false); return; } const watcher = navigator.geolocation.watchPosition((p) => updatePosition(p.coords, true), () => setError('No se pudo actualizar la ubicación. Revisa los permisos.'), { enableHighAccuracy: true, maximumAge: 10000 });
    const heartbeat = setInterval(() => navigator.geolocation.getCurrentPosition((p) => updatePosition(p.coords, true), () => {}, { enableHighAccuracy: true, maximumAge: 10000, timeout: 10000 }), 15000);
    return () => { navigator.geolocation.clearWatch(watcher); clearInterval(heartbeat); }; }, [online]);
  async function toggleOnline() { setError(''); if (online) { try { await rpc('driver_set_location', { p_lat: null, p_lng: null, p_online: false }); } catch (err) { setError(err.message); } setOnline(false); return; } if (!navigator.geolocation) return setError('Activa la ubicación en este dispositivo.'); navigator.geolocation.getCurrentPosition(async (p) => { await updatePosition(p.coords, true); setOnline(true); }, () => setError('Debes permitir el acceso a la ubicación para conectarte.'), { enableHighAccuracy: true, timeout: 12000 }); }
  async function accept(rideId) { setBusy(rideId); setError(''); try { await rpc('accept_ride', { p_ride_id: rideId }); await refresh(); } catch (err) { setError(err.message); } setBusy(''); }
  async function setRideStatus(next) { if (!activeRide) return; setBusy('status'); try { await rpc('update_driver_ride_status', { p_ride_id: activeRide.id, p_status: next }); await refresh(); } catch (err) { setError(err.message); } setBusy(''); }
  return <Page><SectionTitle kicker="PANEL DEL CONDUCTOR" title={`¡Hola, ${(profile.full_name || '').split(' ')[0] || 'conductor'}!`} subtitle="Conéctate para recibir solicitudes cercanas y gestionar tus servicios." action={<button className={`online-toggle ${online ? 'is-online' : ''}`} onClick={toggleOnline}><Power size={16}/>{online ? 'Estás conectado' : 'Conectarme'}</button>}/>{error && <div className="alert error page-alert">{error}</div>}<div className="driver-stats"><div className="metric-card"><span className="metric-icon yellow"><Navigation size={19}/></span><div><small>ESTADO</small><b>{online ? 'Disponible' : 'Desconectado'}</b></div><i className={online ? 'metric-live' : ''}/></div><div className="metric-card"><span className="metric-icon blue"><MapPin size={19}/></span><div><small>UBICACIÓN</small><b>{location ? 'Actualizada' : 'Sin ubicación'}</b></div></div><div className="metric-card"><span className="metric-icon purple"><CarFront size={19}/></span><div><small>SERVICIO ACTUAL</small><b>{activeRide ? 'En curso' : 'Ninguno'}</b></div></div></div>
    {activeRide && <motion.section variants={fadeUp} className="content-card active-trip"><div className="card-heading"><div><span className="eyebrow">SERVICIO ASIGNADO</span><h2>Viaje en curso</h2></div><span className={`status-chip status-${activeRide.status}`}>{statusLabel[activeRide.status]}</span></div><div className="trip-route"><span className="route-icon"><MapPin size={17}/></span><div><small>RECOGIDA</small><b>{activeRide.pickup_label}</b></div><span className="route-arrow"><ArrowRight size={17}/></span><div><small>DESTINO</small><b>{activeRide.destination_label || 'Por definir'}</b></div></div><div className="action-row">{activeRide.status === 'accepted' ? <button className="btn btn-primary" onClick={() => setRideStatus('in_progress')} disabled={busy === 'status'}>Iniciar viaje <ArrowRight size={16}/></button> : <button className="btn btn-primary" onClick={() => setRideStatus('completed')} disabled={busy === 'status'}>Finalizar servicio <Check size={16}/></button>}</div></motion.section>}
    <motion.section variants={fadeUp} className="content-card offers-card"><div className="card-heading"><div><span className="eyebrow">SOLICITUDES CERCANAS</span><h2>Viajes disponibles</h2><p>Solo aparecen solicitudes donde eres el conductor disponible más cercano.</p></div><span className="count-badge">{offers.length} nuevas</span></div>{!online ? <EmptyState icon={Power} title="Conéctate para recibir viajes" text="Activa tu disponibilidad y permite el acceso a tu ubicación."/> : offers.length ? <div className="offer-list">{offers.map((r) => <div className="offer-row" key={r.id}><div className="offer-main"><span className="offer-icon"><CarFront size={20}/></span><div><b>{r.passenger_name || 'Pasajero'}</b><small><MapPin size={13}/> {r.pickup_label}</small><small><Navigation size={13}/> {r.destination_label || 'Destino por definir'}</small>{r.passenger_phone && <small><Phone size={12}/> {r.passenger_phone}</small>}</div></div><div className="offer-distance">{Number(r.distance_km).toFixed(1)} km</div><button className="btn btn-primary btn-small" onClick={() => accept(r.id)} disabled={!!busy || !!activeRide}>{busy === r.id ? 'Aceptando…' : 'Aceptar'}</button></div>)}</div> : <EmptyState title="No hay solicitudes cerca" text="Te avisaremos cuando haya un pasajero en tu zona."/>}</motion.section>
    <motion.section variants={fadeUp} className="content-card docs-card"><div className="card-heading"><div><span className="eyebrow">PERFIL PROFESIONAL</span><h2>Mis documentos</h2></div><span className="count-badge">{docs.length} archivos</span></div>{docs.length ? <div className="documents-list">{docs.map((d) => <a href={d.drive_url} target="_blank" rel="noreferrer" key={d.id} className="document-row"><FileText size={18}/><span><b>{d.title}</b><small>Documento compartido por administración</small></span><ArrowRight size={16}/></a>)}</div> : <EmptyState icon={FileText} title="Aún no hay documentos" text="La administración agregará aquí los enlaces de tus documentos."/>}</motion.section></Page>;
}

const DEFAULT_DOCS = [{ title: 'Documento de identidad', url: '' }, { title: 'Licencia de conducción', url: '' }, { title: 'Documentos del vehículo', url: '' }];
const blankForm = () => ({ full_name: '', email: '', phone: '', username: '', password: '', vehicle_make: '', vehicle_model: '', vehicle_color: '', plate: '', documents: DEFAULT_DOCS.map((d) => ({ ...d })) });

function AdminDashboard({ profile }) {
  const [drivers, setDrivers] = useState([]);
  const [usersCount, setUsersCount] = useState(0);
  const [ridesCount, setRidesCount] = useState(0);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [form, setForm] = useState(blankForm);
  const load = useCallback(async () => {
    try { const d = await rpc('admin_dashboard'); setDrivers(d.drivers || []); setUsersCount(d.users_count || 0); setRidesCount(d.rides_count || 0); } catch { /* se reintenta */ }
  }, []);
  useEffect(() => { load(); const t = setInterval(load, 10000); return () => clearInterval(t); }, [load]);
  const setDoc = (index, key, value) => setForm((f) => ({ ...f, documents: f.documents.map((d, i) => i === index ? { ...d, [key]: value } : d) }));
  function closeForm() { setShowForm(false); setEditingId(null); setForm(blankForm()); }
  function openEdit(d) {
    const existing = (d.driver_documents || []).map((x) => ({ title: x.title, url: x.drive_url }));
    const extra = DEFAULT_DOCS.filter((t) => !existing.some((x) => x.title === t.title)).map((t) => ({ ...t }));
    const v = d.driver_details || {};
    setForm({ full_name: d.full_name || '', email: d.email || '', phone: d.phone || '', username: d.username || '', password: '', vehicle_make: v.vehicle_make || '', vehicle_model: v.vehicle_model || '', vehicle_color: v.vehicle_color || '', plate: v.plate || '', documents: [...existing, ...extra] });
    setEditingId(d.id); setShowForm(true); setError(''); setSuccess('');
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }
  async function saveDriver(e) {
    e.preventDefault(); setBusy(true); setError(''); setSuccess('');
    try {
      const docs = form.documents.filter((d) => d.url.trim()).map((d) => ({ title: d.title.trim(), drive_url: d.url.trim() }));
      const base = { p_name: form.full_name, p_email: form.email, p_phone: form.phone, p_password: form.password, p_make: form.vehicle_make, p_model: form.vehicle_model, p_color: form.vehicle_color, p_plate: form.plate, p_docs: docs };
      if (editingId) { await rpc('admin_update_driver', { ...base, p_driver_id: editingId, p_username: form.username }); setSuccess(`Conductor ${form.full_name} actualizado correctamente.`); }
      else { await rpc('admin_create_driver', base); setSuccess(`Conductor ${form.full_name} creado correctamente.`); }
      setForm(blankForm()); setEditingId(null); setShowForm(false); await load();
    } catch (err) { setError(err.message || 'No fue posible guardar el conductor.'); }
    finally { setBusy(false); }
  }
  return <Page><SectionTitle kicker="CENTRO DE CONTROL" title="Administración" subtitle="Gestiona los conductores, sus documentos y la operación de Taxi Cerca." action={<button className="btn btn-primary" onClick={() => { setError(''); setSuccess(''); if (showForm && !editingId) closeForm(); else { setEditingId(null); setForm(blankForm()); setShowForm(true); } }}><Plus size={17}/> Crear conductor</button>}/>{error && <div className="alert error page-alert">{error}</div>}{success && <div className="alert success page-alert">{success}</div>}<div className="admin-stats"><div className="admin-stat"><span className="stat-symbol stat-yellow"><Users size={20}/></span><div><small>PASAJEROS REGISTRADOS</small><strong><CountUp value={usersCount}/></strong><span>Usuarios en la plataforma</span></div></div><div className="admin-stat"><span className="stat-symbol stat-blue"><CarFront size={20}/></span><div><small>CONDUCTORES</small><strong><CountUp value={drivers.length}/></strong><span>Perfiles creados</span></div></div><div className="admin-stat"><span className="stat-symbol stat-purple"><Navigation size={20}/></span><div><small>SERVICIOS REGISTRADOS</small><strong><CountUp value={ridesCount}/></strong><span>Solicitudes de viaje</span></div></div></div>
    {showForm && <motion.section variants={fadeUp} className="content-card create-driver-card"><div className="card-heading"><div><span className="eyebrow">{editingId ? 'EDITAR PERFIL' : 'NUEVO PERFIL'}</span><h2>{editingId ? 'Modificar conductor' : 'Registrar conductor'}</h2><p>{editingId ? 'Actualiza sus datos, vehículo y documentos. Deja la contraseña vacía para no cambiarla.' : 'La cuenta se crea con acceso de conductor y los documentos quedan asociados a su perfil.'}</p></div><button className="icon-button" onClick={closeForm}><X size={19}/></button></div><form onSubmit={saveDriver} className="admin-form"><div className="form-section-label"><UserRound size={16}/> Datos personales y acceso</div><div className="field-grid"><label>Nombre completo<input required value={form.full_name} onChange={(e) => setForm({...form, full_name:e.target.value})} placeholder="Nombre del conductor"/></label><label>Teléfono<input required value={form.phone} onChange={(e) => setForm({...form, phone:e.target.value})} placeholder="300 000 0000"/></label><label>Correo de acceso<input required={!editingId} type="email" value={form.email} onChange={(e) => setForm({...form, email:e.target.value})} placeholder="conductor@correo.com"/></label><label>{editingId ? 'Nueva contraseña (opcional)' : 'Contraseña temporal'}<input required={!editingId} type="password" minLength={5} autoComplete="new-password" value={form.password} onChange={(e) => setForm({...form, password:e.target.value})} placeholder={editingId ? 'Dejar vacío para no cambiarla' : 'Mínimo 5 caracteres'}/></label>{editingId && <label>Usuario (opcional)<input autoCapitalize="none" value={form.username} onChange={(e) => setForm({...form, username:e.target.value})} placeholder="usuario.conductor"/></label>}</div><div className="form-section-label"><CarFront size={16}/> Información del taxi</div><div className="field-grid three-fields"><label>Marca<input value={form.vehicle_make} onChange={(e) => setForm({...form, vehicle_make:e.target.value})} placeholder="Chevrolet"/></label><label>Modelo<input value={form.vehicle_model} onChange={(e) => setForm({...form, vehicle_model:e.target.value})} placeholder="Beat"/></label><label>Color<input value={form.vehicle_color} onChange={(e) => setForm({...form, vehicle_color:e.target.value})} placeholder="Amarillo"/></label><label>Placa<input value={form.plate} onChange={(e) => setForm({...form, plate:e.target.value.toUpperCase()})} placeholder="ABC123"/></label></div><div className="form-section-label"><FileText size={16}/> Documentos en Google Drive</div><p className="form-help">Pega enlaces compartidos que permitan la lectura al personal autorizado. No subas documentos directamente al código.</p><div className="documents-form">{form.documents.map((d, i) => <label key={i}>{d.title}<input type="url" value={d.url} onChange={(e) => setDoc(i, 'url', e.target.value)} placeholder="https://drive.google.com/file/d/…"/></label>)}</div><div className="form-actions"><button type="button" className="btn btn-outline" onClick={closeForm}>Cancelar</button><button className="btn btn-primary" disabled={busy}>{busy ? 'Guardando…' : editingId ? 'Guardar cambios' : 'Crear conductor'} <ArrowRight size={16}/></button></div></form></motion.section>}
    <motion.section variants={fadeUp} className="content-card driver-management"><div className="card-heading"><div><span className="eyebrow">TU EQUIPO</span><h2>Conductores registrados</h2></div><span className="count-badge">{drivers.length} perfiles</span></div>{drivers.length ? <div className="driver-table-wrap"><table className="driver-table"><thead><tr><th>CONDUCTOR</th><th>VEHÍCULO</th><th>PLACA</th><th>DOCUMENTOS</th><th>REGISTRO</th><th></th></tr></thead><tbody>{drivers.map((d) => <tr key={d.id}><td><div className="table-person"><span className="avatar">{(d.full_name || 'C').slice(0,1).toUpperCase()}</span><span><b>{d.full_name}</b><small>{d.email || d.username || d.phone || 'Sin contacto'}</small></span></div></td><td>{[d.driver_details?.vehicle_make, d.driver_details?.vehicle_model].filter(Boolean).join(' ') || 'Sin datos'}<small className="table-sub">{d.driver_details?.vehicle_color || ''}</small></td><td><span className="plate-chip">{d.driver_details?.plate || '—'}</span></td><td><div className="doc-links">{(d.driver_documents || []).length ? d.driver_documents.map((doc) => <a href={doc.drive_url} target="_blank" rel="noreferrer" key={doc.id} title={doc.title}><FileText size={15}/></a>) : <span className="muted">Sin documentos</span>}</div></td><td>{new Date(d.created_at).toLocaleDateString('es-CO')}</td><td><button type="button" className="btn btn-outline btn-small btn-edit" onClick={() => openEdit(d)}><Pencil size={14}/> Editar</button></td></tr>)}</tbody></table></div> : <EmptyState icon={Users} title="Aún no has creado conductores" text="Usa el botón Crear conductor para registrar el primer perfil."/>}</motion.section></Page>;
}

export default function App() {
  const [profile, setProfile] = useState(null);
  const [loading, setLoading] = useState(true);
  const portal = usePortal();
  const clearSession = useCallback(() => { setToken(null); setProfile(null); }, []);
  useEffect(() => {
    if (!isSupabaseConfigured || !getToken()) { setLoading(false); return; }
    rpc('app_me').then(setProfile).catch(() => setToken(null)).finally(() => setLoading(false));
  }, []);
  useEffect(() => { window.addEventListener('session-expired', clearSession); return () => window.removeEventListener('session-expired', clearSession); }, [clearSession]);
  useEffect(() => {
    if (profile && portal && profile.role !== portal.role) { rpc('app_logout').catch(() => {}).finally(clearSession); }
  }, [profile, portal, clearSession]);
  async function signOut() { try { await rpc('app_logout'); } catch { /* ya expiró */ } clearSession(); }
  if (!isSupabaseConfigured) return <ConfigNotice/>;
  if (loading) return <div className="loading-screen"><div className="loader-mark"><CarFront size={26}/></div><span>Preparando tu experiencia…</span></div>;
  if (!profile || (portal && profile.role !== portal.role)) return <AuthScreen onAuth={setProfile} portal={portal}/>;
  const role = profile.role;
  return <Shell profile={profile} role={role} onSignOut={signOut} active={role === 'admin' ? 'Panel' : role === 'driver' ? 'Panel' : 'Inicio'}>{role === 'admin' ? <AdminDashboard profile={profile}/> : role === 'driver' ? <DriverDashboard profile={profile}/> : <UserDashboard profile={profile}/>}</Shell>;
}

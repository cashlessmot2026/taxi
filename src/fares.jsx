import { useCallback, useEffect, useState } from 'react';
import { motion } from 'motion/react';
import { Ban, Check, Clock3, Gauge, HandCoins, Navigation, Plus, Route, Trash2, Wallet } from 'lucide-react';
import { rpc } from './api';

export const cop = (v) => new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', maximumFractionDigits: 0 }).format(Number(v) || 0);
const toInt = (v) => { const n = Math.round(Number(String(v).replace(/[^\d]/g, ''))); return Number.isFinite(n) ? n : 0; };
const fadeUp = { hidden: { opacity: 0, y: 14 }, show: { opacity: 1, y: 0, transition: { duration: 0.45, ease: [0.22, 1, 0.36, 1] } } };

// ---- Tarifa de la plataforma = mayor entre la tarifa mínima del sector y (km recorridos × valor por km)
export const platformFare = (ride, km = ride?.distance_km_traveled || 0) =>
  Math.max(Number(ride?.min_fare) || 0, Math.round((Number(km) || 0) * (Number(ride?.price_per_km) || 0)));

// Valor a pagar: con tarifa de la plataforma = por km; si no, el valor acordado por el conductor (o por km si no hubo cotización).
export const amountDue = (ride) => {
  if (ride?.final_fare != null) return Number(ride.final_fare);
  if (ride?.use_platform_rate) return platformFare(ride);
  return ride?.quote_total != null ? Number(ride.quote_total) : platformFare(ride);
};

export function useFares() {
  const [fares, setFares] = useState({ sectors: [], price_per_km: 0 });
  const load = useCallback(async () => { try { setFares(await rpc('fares_public')); } catch { /* sin datos de tarifas todavía */ } }, []);
  useEffect(() => { load(); const t = setInterval(load, 30000); return () => clearInterval(t); }, [load]);
  return fares;
}

export function fmtDuration(total) {
  const s = Math.max(0, Math.floor(total));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
}

function useElapsed(startedAt, offset = 0) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => { if (!startedAt) return undefined; const t = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(t); }, [startedAt]);
  return startedAt ? Math.max(0, Math.floor((now + offset - new Date(startedAt).getTime()) / 1000)) : 0;
}

// ---- Tarifas visibles (cliente y conductor)
export function FareSectorsCard({ data, id = 'tarifas' }) {
  return <motion.section variants={fadeUp} id={id} className="content-card fares-card">
    <div className="card-heading"><div><span className="eyebrow">TARIFAS</span><h2>Tarifas mínimas por sector</h2><p>Valor mínimo de la carrera. El conductor suma un valor adicional según el trayecto.</p></div><span className="count-badge">{data.sectors.length} sectores</span></div>
    {data.sectors.length ? <div className="fare-grid">{data.sectors.map((s) => <div className="fare-chip" key={s.id}><span><Wallet size={16}/></span><div><b>{s.name}</b><small>Mínima</small></div><strong>{cop(s.min_fare)}</strong></div>)}</div>
      : <div className="empty-state"><span><Wallet size={24}/></span><b>Aún no hay tarifas</b><p>La administración publicará aquí las tarifas mínimas por sector.</p></div>}
    <div className="fare-km"><Route size={16}/> Tarifa de la plataforma por kilómetro recorrido: <b>{data.price_per_km ? `${cop(data.price_per_km)} / km` : 'por definir'}</b></div>
  </motion.section>;
}

// ---- Propina
const TIPS = [1000, 2000, 5000];
export function TipPicker({ value, onChange }) {
  const custom = value && !TIPS.includes(value);
  return <div className="tip-picker">
    <div className="tip-chips">
      {TIPS.map((t) => <button type="button" key={t} className={`chip ${value === t ? 'chip-on' : ''}`} onClick={() => onChange(value === t ? 0 : t)}>{cop(t)}</button>)}
      <label className={`tip-custom ${custom ? 'is-on' : ''}`}>Otro<input inputMode="numeric" value={custom ? value : ''} onChange={(e) => onChange(Math.min(1000000, toInt(e.target.value)))} placeholder="$ valor"/></label>
    </div>
    {value > 0 && <small className="tip-note"><HandCoins size={13}/> Propina para el conductor: <b>{cop(value)}</b></small>}
  </div>;
}

// ---- Cotización del conductor (antes de aceptar)
export function QuoteBox({ ride, value, onChange }) {
  const add = toInt(value);
  const total = (Number(ride.min_fare) || 0) + add;
  return <div className="quote-box">
    <div className="quote-line"><span>Sector</span><b>{ride.sector_name || 'Sin sector'}</b></div>
    <div className="quote-line"><span>Tarifa mínima</span><b>{cop(ride.min_fare)}</b></div>
    <label className="quote-input"><span>Valor adicional (opcional)</span><input inputMode="numeric" value={value} onChange={(e) => onChange(e.target.value.replace(/[^\d]/g, ''))} placeholder="$ 0"/></label>
    <div className="quote-total"><span>Valor aproximado del trayecto</span><b>{cop(total)}</b></div>
    {ride.tip_amount > 0 && <div className="quote-line"><span>Propina del cliente</span><b>{cop(ride.tip_amount)}</b></div>}
  </div>;
}

// ---- Contador de tiempo y kilómetros (cliente y conductor)
export function TripMeter({ ride, offset = 0 }) {
  const live = ride.status === 'in_progress';
  const secs = useElapsed(live ? ride.started_at : null, offset);
  if (!live) return null;
  const km = Number(ride.distance_km_traveled) || 0;
  return <div className="trip-meter">
    <div className="meter-cell"><Clock3 size={18}/><div><small>TIEMPO</small><b className="meter-num">{fmtDuration(secs)}</b></div></div>
    <div className="meter-cell"><Navigation size={18}/><div><small>RECORRIDO</small><b className="meter-num">{km.toFixed(2)} km</b></div></div>
    <div className="meter-cell"><Gauge size={18}/><div><small>POR KILÓMETROS</small><b className="meter-num">{cop(platformFare(ride))}</b></div></div>
    <div className="meter-cell meter-due"><Wallet size={18}/><div><small>VALOR A PAGAR</small><b className="meter-num">{cop(amountDue(ride))}</b></div></div>
  </div>;
}

function FareLines({ ride }) {
  return <div className="fare-lines">
    {ride.sector_name && <div className="quote-line"><span>Sector</span><b>{ride.sector_name}</b></div>}
    {ride.min_fare != null && <div className="quote-line"><span>Tarifa mínima</span><b>{cop(ride.min_fare)}</b></div>}
    {ride.quote_additional != null && <div className="quote-line"><span>Valor adicional del conductor</span><b>{cop(ride.quote_additional)}</b></div>}
    {ride.quote_total != null && <div className="quote-total"><span>Valor aproximado</span><b>{cop(ride.quote_total)}</b></div>}
    {ride.status === 'in_progress' && <div className="quote-line"><span>Por kilómetros ({(Number(ride.distance_km_traveled) || 0).toFixed(2)} km × {cop(ride.price_per_km || 0)})</span><b>{cop(platformFare(ride))}</b></div>}
    {ride.use_platform_rate && <div className="quote-line platform-on"><span>El conductor cobra con la tarifa de la plataforma</span><b>Activa</b></div>}
    {ride.status === 'in_progress' && <div className="quote-total"><span>Valor a pagar{ride.use_platform_rate ? ' (tarifa plataforma)' : ''}</span><b>{cop(amountDue(ride))}</b></div>}
    {ride.tip_amount > 0 && <div className="quote-line"><span>Propina</span><b>{cop(ride.tip_amount)}</b></div>}
    {ride.tip_amount > 0 && ride.status === 'in_progress' && <div className="quote-line"><span>Total con propina</span><b>{cop(amountDue(ride) + Number(ride.tip_amount))}</b></div>}
  </div>;
}

// ---- Panel de tarifas del viaje en el perfil del cliente
export function ClientFarePanel({ ride, offset, onTip }) {
  const [editing, setEditing] = useState(false);
  const canTip = ['pending', 'accepted', 'in_progress'].includes(ride.status);
  return <div className="trip-fares">
    <TripMeter ride={ride} offset={offset}/>
    <FareLines ride={ride}/>
    {canTip && <div className="tip-edit">
      <button type="button" className="btn btn-outline btn-small" onClick={() => setEditing(!editing)}><HandCoins size={14}/> {ride.tip_amount > 0 ? 'Cambiar propina' : 'Agregar propina'}</button>
      {editing && <TipPicker value={ride.tip_amount || 0} onChange={onTip}/>}
    </div>}
  </div>;
}

// ---- Panel de tarifas del viaje en el perfil del conductor
export function DriverFarePanel({ ride, offset, onChanged, onError }) {
  const [add, setAdd] = useState(ride.quote_additional != null ? String(ride.quote_additional) : '');
  const [busy, setBusy] = useState(false);
  useEffect(() => { setAdd(ride.quote_additional != null ? String(ride.quote_additional) : ''); }, [ride.id, ride.quote_additional]);
  async function run(fn, args) { setBusy(true); try { await rpc(fn, args); await onChanged(); } catch (e) { onError(e.message); } setBusy(false); }
  const accepted = ride.status === 'accepted';
  return <div className="trip-fares">
    <TripMeter ride={ride} offset={offset}/>
    {accepted && <div className="quote-box">
      <div className="quote-line"><span>Sector</span><b>{ride.sector_name || 'Sin sector'}</b></div>
      <div className="quote-line"><span>Tarifa mínima</span><b>{cop(ride.min_fare)}</b></div>
      <label className="quote-input"><span>Valor adicional</span><input inputMode="numeric" value={add} onChange={(e) => setAdd(e.target.value.replace(/[^\d]/g, ''))} placeholder="$ 0"/></label>
      <div className="quote-total"><span>Valor aproximado</span><b>{cop((Number(ride.min_fare) || 0) + toInt(add))}</b></div>
      <button type="button" className="btn btn-outline btn-small" disabled={busy} onClick={() => run('driver_quote_ride', { p_ride_id: ride.id, p_additional: toInt(add) })}>Guardar valor</button>
    </div>}
    {!accepted && <FareLines ride={ride}/>}
    {ride.tip_amount > 0 && accepted && <div className="quote-line"><span>Propina del cliente</span><b>{cop(ride.tip_amount)}</b></div>}
    <button type="button" className={`btn btn-small platform-toggle ${ride.use_platform_rate ? 'is-on' : ''}`} disabled={busy} onClick={() => run('driver_set_platform_rate', { p_ride_id: ride.id, p_use: !ride.use_platform_rate })}>
      {ride.use_platform_rate ? <><Check size={14}/> Cobrando con tarifa de la plataforma</> : <><Ban size={14}/> Cobrar con tarifa de la plataforma</>}
    </button>
    <small className="platform-help">Tarifa plataforma = el mayor entre la tarifa mínima y los km recorridos × el valor por km{ride.price_per_km ? ` (${cop(ride.price_per_km)}/km)` : ''}.</small>
  </div>;
}

// ---- Administración: tarifas por sector y valor por kilómetro
function SectorRow({ sector, onSave, onDelete }) {
  const [name, setName] = useState(sector.name);
  const [fare, setFare] = useState(String(sector.min_fare));
  const dirty = name !== sector.name || toInt(fare) !== sector.min_fare;
  return <tr className={sector.is_active ? '' : 'row-disabled'}>
    <td><input className="cell-input" value={name} onChange={(e) => setName(e.target.value)}/></td>
    <td><input className="cell-input" inputMode="numeric" value={fare} onChange={(e) => setFare(e.target.value.replace(/[^\d]/g, ''))}/></td>
    <td>{sector.is_active ? <span className="state-chip state-ok"><i/>Visible</span> : <span className="state-chip state-off"><i/>Oculto</span>}</td>
    <td><div className="row-actions">
      <button type="button" className="btn btn-primary btn-small" disabled={!dirty} onClick={() => onSave({ id: sector.id, name, min_fare: toInt(fare), is_active: sector.is_active })}>Guardar</button>
      <button type="button" className="btn btn-outline btn-small" onClick={() => onSave({ id: sector.id, name: sector.name, min_fare: sector.min_fare, is_active: !sector.is_active })}>{sector.is_active ? 'Ocultar' : 'Mostrar'}</button>
      <button type="button" className="btn btn-disable btn-small" onClick={() => onDelete(sector)}><Trash2 size={14}/></button>
    </div></td>
  </tr>;
}

export function AdminFares() {
  const [data, setData] = useState({ sectors: [], price_per_km: 0 });
  const [price, setPrice] = useState('');
  const [newName, setNewName] = useState('');
  const [newFare, setNewFare] = useState('');
  const [msg, setMsg] = useState({ type: '', text: '' });
  const load = useCallback(async () => {
    try { const d = await rpc('admin_fares'); setData(d); setPrice((p) => (p === '' ? String(d.price_per_km || 0) : p)); }
    catch (e) { setMsg({ type: 'error', text: `${e.message}. Verifica que ejecutaste el SQL 009 en Supabase.` }); }
  }, []);
  useEffect(() => { load(); }, [load]);
  const ok = (text) => setMsg({ type: 'success', text });
  const fail = (e) => setMsg({ type: 'error', text: e.message });
  async function savePrice(e) { e.preventDefault(); try { await rpc('admin_set_price_per_km', { p_value: toInt(price) }); ok('Valor por kilómetro actualizado.'); await load(); } catch (err) { fail(err); } }
  async function saveSector(s) { try { await rpc('admin_save_sector', { p_id: s.id || null, p_name: s.name, p_min_fare: s.min_fare, p_active: s.is_active }); ok('Sector guardado.'); await load(); return true; } catch (err) { fail(err); return false; } }
  async function addSector(e) { e.preventDefault(); if (await saveSector({ name: newName, min_fare: toInt(newFare), is_active: true })) { setNewName(''); setNewFare(''); } }
  async function deleteSector(s) { if (!window.confirm(`¿Eliminar el sector "${s.name}"? Los viajes anteriores conservan su tarifa.`)) return; try { await rpc('admin_delete_sector', { p_id: s.id }); ok('Sector eliminado.'); await load(); } catch (err) { fail(err); } }
  return <motion.div variants={{ hidden: {}, show: { transition: { staggerChildren: 0.08 } } }} initial="hidden" animate="show">
    <motion.div variants={fadeUp} className="section-title"><div><span className="eyebrow">TARIFAS</span><h1>Tarifas y valor por kilómetro</h1><p>Define la tarifa mínima por sector y cuánto se cobra por kilómetro recorrido cuando el conductor usa la tarifa de la plataforma.</p></div></motion.div>
    {msg.text && <div className={`alert ${msg.type} page-alert`}>{msg.text}</div>}
    <motion.section variants={fadeUp} className="content-card">
      <div className="card-heading"><div><span className="eyebrow">TARIFA DE LA PLATAFORMA</span><h2>Valor por kilómetro recorrido</h2><p>El conductor puede activarla en cada servicio. Se cobra el mayor entre la tarifa mínima del sector y los km recorridos × este valor.</p></div></div>
      <form className="price-form" onSubmit={savePrice}><label>Valor por km (COP)<input inputMode="numeric" value={price} onChange={(e) => setPrice(e.target.value.replace(/[^\d]/g, ''))} placeholder="Ej. 2500"/></label><button className="btn btn-primary"><Check size={16}/> Guardar</button><span className="price-now">Actual: <b>{cop(data.price_per_km)} / km</b></span></form>
    </motion.section>
    <motion.section variants={fadeUp} className="content-card">
      <div className="card-heading"><div><span className="eyebrow">POR SECTOR</span><h2>Tarifas mínimas</h2><p>Los clientes y los conductores las ven en su perfil. Los sectores ocultos no se pueden elegir.</p></div><span className="count-badge">{data.sectors.length} sectores</span></div>
      <form className="sector-add" onSubmit={addSector}><label>Sector<input required value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="Ej. Chapinero – Centro"/></label><label>Tarifa mínima (COP)<input required inputMode="numeric" value={newFare} onChange={(e) => setNewFare(e.target.value.replace(/[^\d]/g, ''))} placeholder="Ej. 8000"/></label><button className="btn btn-primary"><Plus size={16}/> Agregar sector</button></form>
      {data.sectors.length ? <div className="driver-table-wrap"><table className="driver-table"><thead><tr><th>SECTOR</th><th>TARIFA MÍNIMA (COP)</th><th>ESTADO</th><th></th></tr></thead><tbody>{data.sectors.map((s) => <SectorRow key={`${s.id}-${s.name}-${s.min_fare}-${s.is_active}`} sector={s} onSave={saveSector} onDelete={deleteSector}/>)}</tbody></table></div>
        : <div className="empty-state"><span><Wallet size={24}/></span><b>Sin sectores</b><p>Agrega el primer sector con su tarifa mínima.</p></div>}
    </motion.section>
  </motion.div>;
}

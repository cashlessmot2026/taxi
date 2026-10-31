import { useEffect, useRef } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';

const GLYPH = { free: '🚕', busy: '🚖', pickup: 'A', dest: 'B', request: '🙋' };

function pin(kind) {
  return L.divIcon({
    className: 'map-pin-wrap',
    html: `<div class="map-pin map-pin-${kind}"><span>${GLYPH[kind] || '•'}</span></div>`,
    iconSize: [38, 44],
    iconAnchor: [19, 44],
    popupAnchor: [0, -40]
  });
}

// markers: [{ kind: 'free'|'busy'|'pickup'|'dest'|'request', lat, lng, label }]
// onPick(lat, lng): si se pasa, el mapa permite tocar para colocar un punto.
export default function MapView({ markers = [], onPick, height = 380 }) {
  const el = useRef(null);
  const map = useRef(null);
  const layer = useRef(null);
  const lastCount = useRef(0);
  const pickRef = useRef(onPick);
  pickRef.current = onPick;

  useEffect(() => {
    const m = L.map(el.current, { zoomControl: true }).setView([4.711, -74.072], 12);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '&copy; OpenStreetMap' }).addTo(m);
    layer.current = L.layerGroup().addTo(m);
    m.on('click', (e) => { if (pickRef.current) pickRef.current(e.latlng.lat, e.latlng.lng); });
    map.current = m;
    const t = setTimeout(() => m.invalidateSize(), 80);
    return () => { clearTimeout(t); m.remove(); map.current = null; layer.current = null; lastCount.current = 0; };
  }, []);

  const sig = markers.map((k) => `${k.kind}:${k.lat}:${k.lng}:${k.label || ''}`).join('|');
  useEffect(() => {
    const g = layer.current, m = map.current;
    if (!g || !m) return;
    g.clearLayers();
    const pts = [];
    markers.forEach((k) => {
      if (k.lat == null || k.lng == null) return;
      const mk = L.marker([k.lat, k.lng], { icon: pin(k.kind) }).addTo(g);
      if (k.label) { const box = document.createElement('div'); box.className = 'map-popup'; box.textContent = k.label; mk.bindPopup(box); }
      pts.push([k.lat, k.lng]);
    });
    if (pts.length && pts.length !== lastCount.current) {
      if (pts.length === 1) m.setView(pts[0], Math.max(m.getZoom(), 15));
      else m.fitBounds(pts, { padding: [50, 50], maxZoom: 16 });
    }
    lastCount.current = pts.length;
  }, [sig]); // eslint-disable-line react-hooks/exhaustive-deps

  return <div ref={el} className={`map-box ${onPick ? 'map-pickable' : ''}`} style={{ height }}/>;
}

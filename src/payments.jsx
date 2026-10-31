import { ArrowLeftRight, CreditCard } from 'lucide-react';

const base = import.meta.env.BASE_URL;

// Logos oficiales en /public/pay (Nequi, Bancolombia y Bre-B). Transferencia y datáfono usan íconos genéricos.
export const PAYMENTS = [
  { id: 'nequi', label: 'Nequi', logo: 'pay/nequi.png' },
  { id: 'bancolombia', label: 'Bancolombia', logo: 'pay/bancolombia.png' },
  { id: 'breb', label: 'Bre-B', logo: 'pay/breb.png', wide: true },
  { id: 'transferencia', label: 'Transferencia', icon: ArrowLeftRight },
  { id: 'datafono', label: 'Datáfono', icon: CreditCard }
];

export const payInfo = (id) => PAYMENTS.find((p) => p.id === id) || null;

export function PayMark({ method, size = 22 }) {
  const p = payInfo(method);
  if (!p) return null;
  if (p.logo) return <img className={`pay-logo ${p.wide ? 'pay-logo-wide' : ''}`} src={`${base}${p.logo}`} alt="" style={{ height: size }}/>;
  const Icon = p.icon;
  return <span className="pay-icon" style={{ width: size, height: size }}><Icon size={Math.round(size * 0.68)}/></span>;
}

export function PayBadge({ method }) {
  const p = payInfo(method);
  if (!p) return null;
  return <span className="pay-badge"><PayMark method={method} size={18}/>{p.label}</span>;
}

export function PayPicker({ value, onChange }) {
  return <div className="pay-picker" role="radiogroup" aria-label="Método de pago">
    {PAYMENTS.map((p) => <button type="button" role="radio" aria-checked={value === p.id} key={p.id} className={`pay-option ${value === p.id ? 'is-selected' : ''}`} onClick={() => onChange(p.id)}>
      <PayMark method={p.id} size={26}/><span>{p.label}</span>
    </button>)}
  </div>;
}

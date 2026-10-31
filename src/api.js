import { supabase } from './supabase';

const KEY = 'taxi_session';
export const getToken = () => { try { return localStorage.getItem(KEY); } catch { return null; } };
export const setToken = (t) => { try { if (t) localStorage.setItem(KEY, t); else localStorage.removeItem(KEY); } catch { /* sin almacenamiento */ } };

// Llama a una función RPC de la base de datos. Adjunta el token de sesión propio salvo que auth=false.
export async function rpc(fn, args = {}, { auth = true } = {}) {
  const { data, error } = await supabase.rpc(fn, auth ? { p_token: getToken(), ...args } : args);
  if (error) {
    if (/Sesión inválida/.test(error.message)) window.dispatchEvent(new Event('session-expired'));
    throw new Error(error.message);
  }
  return data;
}

import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL || 'https://bjcmcicaszkkzpxvyalg.supabase.co';
const key = import.meta.env.VITE_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJqY21jaWNhc3pra3pweHZ5YWxnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcxMDA2MTAsImV4cCI6MjEwMjY3NjYxMH0.uX58R-1dEzo25465uZaFzxWmdUbHZdZ5k5EGKMW7AiA';
export const isSupabaseConfigured = Boolean(url && key && !url.includes('TU-PROYECTO') && !key.includes('TU_CLAVE'));
export const supabase = isSupabaseConfigured
  ? createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } })
  : null;

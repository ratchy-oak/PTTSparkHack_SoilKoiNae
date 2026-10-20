import { createClient, type SupabaseClient } from '@supabase/supabase-js';
let client: SupabaseClient | undefined;
export function browserDatabase() {
  if (client) return client;
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) throw new Error('ยังไม่ได้ตั้งค่าการเชื่อมต่อ');
  client = createClient(url,key);
  return client;
}

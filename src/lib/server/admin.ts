import "server-only";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";
export function createAdminClient(){
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL, key=process.env.SUPABASE_SERVICE_ROLE_KEY;
  if(!url||!key) throw new Error("SUPABASE_SERVICE_ROLE_KEY is required for server-only operations");
  return createSupabaseClient(url,key,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false},global:{headers:{"X-Client-Info":"gymflow-server/0.5"}}});
}

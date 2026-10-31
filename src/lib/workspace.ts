import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
export type GymSummary={id:string;name:string;timezone:string;role:string};
export async function getVerifiedUser(){
  const supabase=await createClient();
  const {data,error}=await supabase.auth.getClaims();
  if(error||!data?.claims?.sub) redirect("/login");
  return {supabase,userId:String(data.claims.sub),email:String(data.claims.email??"")};
}
export async function getUserGyms(supabase:any,userId:string):Promise<GymSummary[]>{
  const {data:rows,error}=await supabase.from("gym_users").select("gym_id,role,created_at").eq("user_id",userId).order("created_at");
  if(error) throw new Error("Could not load gym access");
  if(!rows?.length) return [];
  const {data:gyms,error:ge}=await supabase.from("gyms").select("id,name,timezone").in("id",rows.map((x:any)=>x.gym_id));
  if(ge) throw new Error("Could not load gym workspaces");
  const byId=new Map((gyms??[]).map((g:any)=>[g.id,g]));
  return rows.flatMap((row:any)=>{const g=byId.get(row.gym_id);return g?[{...g,role:row.role}]:[];});
}
export async function requireActiveGym(){
  const {supabase,userId,email}=await getVerifiedUser();
  const gyms=await getUserGyms(supabase,userId);
  if(!gyms.length) redirect("/onboarding");
  return {supabase,userId,email,gym:gyms[0],gyms};
}

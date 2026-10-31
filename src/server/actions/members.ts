"use server";
import {revalidatePath} from "next/cache";
import {redirect} from "next/navigation";
import {z} from "zod";
import {requireActiveGym} from "@/lib/workspace";
import {normalizeIndianPhone} from "@/domain/phone.js";
const schema=z.object({name:z.string().trim().min(1).max(120),phone:z.string().trim().min(8).max(20),address:z.string().trim().max(500).optional(),requestKey:z.string().uuid()});
export async function createMemberAction(formData:FormData){const parsed=schema.safeParse({name:formData.get("name"),phone:formData.get("phone"),address:formData.get("address")||"",requestKey:formData.get("request_key")});if(!parsed.success) redirect("/app/members?error=invalid");const phone=normalizeIndianPhone(parsed.data.phone);if(!phone) redirect("/app/members?error=phone");const {supabase,gym}=await requireActiveGym();const {error}=await supabase.rpc("create_member_for_gym",{target_gym:gym.id,member_name:parsed.data.name,member_phone:phone,member_address:parsed.data.address||null,p_request_key:parsed.data.requestKey});if(error) redirect(`/app/members?error=${error.message.includes("member_id_space_exhausted")?"exhausted":"create"}`);revalidatePath("/app/members");revalidatePath("/app");redirect("/app/members?created=1");}

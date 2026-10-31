"use server";
import {revalidatePath} from "next/cache";
import {redirect} from "next/navigation";
import {z} from "zod";
import {requireActiveGym} from "@/lib/workspace";
import {rupeesToPaise} from "@/domain/money.js";
const schema=z.object({name:z.string().trim().min(2).max(100),durationType:z.enum(["months","days"]),duration:z.coerce.number().int().min(1).max(3650),price:z.string().trim().min(1).max(14)});
export async function createPlanAction(formData:FormData){const p=schema.safeParse({name:formData.get("name"),durationType:formData.get("duration_type"),duration:formData.get("duration"),price:formData.get("price_rupees")});if(!p.success) redirect("/app/plans?error=invalid");let amount;try{amount=rupeesToPaise(p.data.price);}catch{redirect("/app/plans?error=price");}const {supabase,gym}=await requireActiveGym();const {error}=await supabase.rpc("create_membership_plan_for_gym",{target_gym:gym.id,plan_name:p.data.name,duration_months:p.data.durationType==="months"?p.data.duration:null,duration_days:p.data.durationType==="days"?p.data.duration:null,price_paise:amount});if(error) redirect("/app/plans?error=create");revalidatePath("/app/plans");redirect("/app/plans?created=1");}

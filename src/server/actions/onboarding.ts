"use server";
import {redirect} from "next/navigation";
import {revalidatePath} from "next/cache";
import {z} from "zod";
import {getVerifiedUser} from "@/lib/workspace";
const schema=z.object({name:z.string().trim().min(2).max(120),timezone:z.string().min(1).max(100)});
export async function createGymAction(formData:FormData){const p=schema.safeParse({name:formData.get("name"),timezone:formData.get("timezone")});if(!p.success) redirect("/onboarding?error=invalid");const {supabase}=await getVerifiedUser();const {error}=await supabase.rpc("create_gym_for_current_user",{gym_name:p.data.name,gym_timezone:p.data.timezone});if(error) redirect("/onboarding?error=create_failed");revalidatePath("/app");redirect("/app");}

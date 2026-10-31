"use server";
import {revalidatePath} from "next/cache";
import {redirect} from "next/navigation";
import {z} from "zod";
import {requireActiveGym} from "@/lib/workspace";
import {rupeesToPaise} from "@/domain/money.js";
const schema=z.object({invoiceId:z.string().uuid(),amount:z.string().trim().min(1).max(14),method:z.enum(["manual_cash","manual_upi","manual_bank"]),reference:z.string().trim().max(180).optional(),requestKey:z.string().uuid()});
export async function recordManualPaymentAction(formData:FormData){const p=schema.safeParse({invoiceId:formData.get("invoice_id"),amount:formData.get("amount_rupees"),method:formData.get("method"),reference:formData.get("reference")||"",requestKey:formData.get("idempotency_key")});if(!p.success) redirect("/app/payments?error=invalid");let amount;try{amount=rupeesToPaise(p.data.amount);}catch{redirect("/app/payments?error=amount");}if(amount<=0) redirect("/app/payments?error=amount");const {supabase,gym}=await requireActiveGym();const {error}=await supabase.rpc("record_manual_payment_for_gym",{target_gym:gym.id,target_invoice:p.data.invoiceId,amount_paise:amount,payment_method:p.data.method,payment_reference:p.data.reference||null,idempotency_key:p.data.requestKey});if(error) redirect(`/app/payments?error=${error.message.includes("payment_exceeds_balance")?"balance":"record"}`);for(const path of ["/app/payments","/app/reports","/app/dues","/app"]) revalidatePath(path);redirect("/app/payments?recorded=1");}

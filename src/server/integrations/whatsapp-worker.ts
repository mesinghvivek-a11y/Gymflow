import {decryptSecret} from "@/lib/server/secret-vault";
import {formatWhatsAppExpiry,whatsappGraphRequest,WhatsAppApiError} from "@/server/integrations/whatsapp.js";
export async function runWhatsAppReminderBatch(admin:any,batchSize=10){
 const skipped=await admin.rpc("skip_ineligible_whatsapp_jobs");if(skipped.error)throw new Error("skip_reminders_failed");
 const pending=await admin.rpc("apply_pending_whatsapp_status_events",{batch_size:100});
 const claim=await admin.rpc("claim_whatsapp_reminder_jobs",{batch_size:Math.max(1,Math.min(batchSize,20))});if(claim.error)throw new Error("claim_reminders_failed");
 const outcomes=[];
 for(const job of claim.data??[]){
  let messageId:string|null=null;
  try{
   const phone=String(job.recipient_phone??"");const template=String(job.template_name??"");
   if(!/^\+[1-9]\d{7,14}$/.test(phone)||!/^[a-z0-9_]{1,512}$/.test(template))throw new Error("invalid_recipient_or_template");
   const token=decryptSecret(job.encrypted_access_token);
   const {data:message,error:insertError}=await admin.from("whatsapp_messages").insert({gym_id:job.gym_id,reminder_job_id:job.job_id,connection_id:job.connection_id,member_id:job.member_id,recipient_phone:phone,template_name:template,status:"sending"}).select("id").single();
   if(insertError||!message?.id)throw new Error("message_log_insert_failed");messageId=message.id;
   const expiry=formatWhatsAppExpiry(job.membership_ends_at,job.gym_timezone);
   const bodyParameters=[job.member_name,job.gym_name,expiry].map(text=>({type:"text",text:String(text).slice(0,60)}));
   const response=await whatsappGraphRequest(`/${encodeURIComponent(job.phone_number_id)}/messages`,token,job.graph_api_version,{method:"POST",body:JSON.stringify({messaging_product:"whatsapp",recipient_type:"individual",to:phone.replace(/^\+/,""),type:"template",template:{name:template,language:{code:job.language_code},components:[{type:"body",parameters:bodyParameters}]}}),signal:AbortSignal.timeout(12000)});
   const providerId=response?.messages?.[0]?.id;if(typeof providerId!=="string"||providerId.length<8)throw new Error("provider_message_id_missing");
   const now=new Date().toISOString();const {error:saveErr}=await admin.from("whatsapp_messages").update({provider_message_id:providerId,status:"accepted",accepted_at:now,updated_at:now}).eq("id",messageId);
   if(saveErr){await admin.from("whatsapp_messages").update({status:"unknown",error_message:"meta_accepted_database_update_failed"}).eq("id",messageId);await admin.from("reminder_jobs").update({status:"unknown",last_error:"meta_accepted_database_update_failed",processed_at:now}).eq("id",job.job_id);outcomes.push("unknown_after_acceptance");continue;}
   await admin.from("reminder_jobs").update({status:"sent",processed_at:now,updated_at:now,last_error:null}).eq("id",job.job_id);outcomes.push("accepted");
  }catch(error){
   const reason=error instanceof Error?error.message.slice(0,300):"unknown_whatsapp_error";
   const definitive=error instanceof WhatsAppApiError&&error.status>=400&&error.status<500&&error.status!==429;
   const status=definitive?"failed":"unknown";const now=new Date().toISOString();
   if(error instanceof WhatsAppApiError&&(error.status===401||error.status===403))await admin.from("whatsapp_connections").update({status:"needs_attention",updated_at:now}).eq("id",job.connection_id);
   if(messageId)await admin.from("whatsapp_messages").update({status,error_message:reason,error_code:error instanceof WhatsAppApiError?error.code:null,updated_at:now}).eq("id",messageId);
   await admin.from("reminder_jobs").update({status,last_error:reason,processed_at:now,updated_at:now}).eq("id",job.job_id);
   outcomes.push(definitive?"failed":"unknown_no_retry");
  }
 }
 return {skipped:Number(skipped.data??0),claimed:claim.data?.length??0,statusEventsApplied:Number(pending.data??0),outcomes};
}

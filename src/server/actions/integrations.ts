"use server";
import {revalidatePath} from "next/cache";
import {redirect} from "next/navigation";
import {z} from "zod";
import {requireActiveGym} from "@/lib/workspace";
import {createAdminClient} from "@/lib/server/admin";
import {encryptSecret,decryptSecret} from "@/lib/server/secret-vault";
import {razorpayRequest,RazorpayApiError} from "@/server/integrations/razorpay.js";
import {whatsappGraphRequest,WhatsAppApiError,validGraphApiVersion} from "@/server/integrations/whatsapp.js";
const canManage=(role:string)=>role==="owner"||role==="manager";
export async function saveRazorpayConnectionAction(formData:FormData){
 const p=z.object({keyId:z.string().trim().regex(/^rzp_(test|live)_[A-Za-z0-9]+$/),keySecret:z.string().min(12).max(256),webhookSecret:z.string().min(12).max(256)}).safeParse({keyId:formData.get("key_id"),keySecret:formData.get("key_secret"),webhookSecret:formData.get("webhook_secret")});
 if(!p.success) redirect("/app/settings?razorpay=invalid");const {gym,userId}=await requireActiveGym();if(!canManage(gym.role))redirect("/app/settings?razorpay=forbidden");
 let admin;try{admin=createAdminClient();}catch{redirect("/app/settings?razorpay=server_config");}
 let keyCipher,hookCipher;try{keyCipher=encryptSecret(p.data.keySecret);hookCipher=encryptSecret(p.data.webhookSecret);}catch{redirect("/app/settings?razorpay=encryption");}
 try{await razorpayRequest("/payments?count=1",{keyId:p.data.keyId,keySecret:p.data.keySecret});}catch(e){if(e instanceof RazorpayApiError&&(e.status===401||e.status===403))redirect("/app/settings?razorpay=auth");redirect("/app/settings?razorpay=unavailable");}
 const {error}=await admin.from("gateway_connections").upsert({gym_id:gym.id,provider:"razorpay",key_id:p.data.keyId,encrypted_key_secret:keyCipher,encrypted_webhook_secret:hookCipher,mode:p.data.keyId.startsWith("rzp_test_")?"test":"live",status:"active",created_by:userId,updated_at:new Date().toISOString()},{onConflict:"gym_id,provider"});
 if(error)redirect("/app/settings?razorpay=save");revalidatePath("/app/settings");redirect("/app/settings?razorpay=saved");
}
export async function createRazorpayLinkAction(formData:FormData){
 const p=z.object({invoiceId:z.string().uuid(),requestKey:z.string().uuid()}).safeParse({invoiceId:formData.get("invoice_id"),requestKey:formData.get("request_key")});
 if(!p.success)redirect("/app/payments?razorpay=invalid");
 const {supabase,gym}=await requireActiveGym();
 const {data:reserved,error}=await supabase.rpc("reserve_razorpay_payment_link",{target_gym:gym.id,target_invoice:p.data.invoiceId,request_key:p.data.requestKey});
 if(error||!reserved?.length)redirect("/app/payments?razorpay=reserve");
 const row=reserved[0];
 let admin;try{admin=createAdminClient();}catch{redirect("/app/payments?razorpay=config");}
 const {data:local}=await admin.from("payment_links").select("id,gateway_connection_id,status,short_url").eq("id",row.payment_link_id).maybeSingle();
 if(local?.status==="created"&&local.short_url)redirect("/app/payments?razorpay=existing");
 // Never repeat the provider POST for an old 'creating' reservation after a timeout.
 if(!local||local.status!=="creating"||row.is_new!==true)redirect("/app/payments?razorpay=unknown");
 const {data:creds}=await admin.from("gateway_connections").select("id,key_id,encrypted_key_secret").eq("id",local.gateway_connection_id).eq("gym_id",gym.id).maybeSingle();
 if(!creds)redirect("/app/payments?razorpay=config");
 let response:any;
 try{
  const secret=decryptSecret(creds.encrypted_key_secret);
  response=await razorpayRequest("/payment_links",{keyId:creds.key_id,keySecret:secret},{method:"POST",body:JSON.stringify({
   amount:Number(row.amount_paise),currency:"INR",accept_partial:false,reference_id:row.reference_id,
   description:`GymFlow invoice ${row.invoice_number}`.slice(0,240),customer:{name:row.member_name,contact:row.member_phone},
   notify:{sms:false,email:false},reminder_enable:false,expire_by:Math.floor(Date.now()/1000)+7*86400,
   notes:{gymflow_payment_link_id:row.payment_link_id,gymflow_invoice_id:row.invoice_id}
  })});
 }catch(error){
  const status=error instanceof RazorpayApiError?error.status:0;
  await admin.from("payment_links").update({status:status>=400&&status<500&&status!==429?"failed":"unknown",last_error:error instanceof Error?error.message.slice(0,250):"provider_error",updated_at:new Date().toISOString()}).eq("id",row.payment_link_id);
  redirect("/app/payments?razorpay=provider_error");
 }
 const url=typeof response.short_url==="string"?response.short_url:"";let safe=false;
 try{const u=new URL(url);safe=u.protocol==="https:"&&(u.hostname==="rzp.io"||u.hostname.endsWith(".razorpay.com"));}catch{}
 if(!safe||Number(response.amount)!==Number(row.amount_paise)||response.currency!=="INR"||response.reference_id!==row.reference_id||typeof response.id!=="string"){
  await admin.from("payment_links").update({status:"needs_review",last_error:"provider_response_mismatch",updated_at:new Date().toISOString()}).eq("id",row.payment_link_id);
  redirect("/app/payments?razorpay=mismatch");
 }
 const {error:saveError}=await admin.from("payment_links").update({provider_link_id:response.id,short_url:url,status:"created",expire_by:response.expire_by?new Date(Number(response.expire_by)*1000).toISOString():null,updated_at:new Date().toISOString()}).eq("id",row.payment_link_id).eq("status","creating");
 if(saveError)redirect("/app/payments?razorpay=needs_review");
 revalidatePath("/app/payments");
 redirect("/app/payments?razorpay=created");
}
export async function saveWhatsAppConnectionAction(formData:FormData){
 const p=z.object({waba:z.string().trim().min(1).max(100),phoneId:z.string().trim().min(1).max(100),token:z.string().min(20).max(4096),version:z.string().regex(/^v\d{1,3}\.\d{1,2}$/),language:z.string().regex(/^[a-z]{2,3}(?:_[A-Z]{2})?$/),pre:z.string().regex(/^[a-z0-9_]{1,512}$/),due:z.string().regex(/^[a-z0-9_]{1,512}$/)}).safeParse({waba:formData.get("business_account_id"),phoneId:formData.get("phone_number_id"),token:formData.get("access_token"),version:formData.get("graph_api_version"),language:formData.get("language_code"),pre:formData.get("pre_expiry_template"),due:formData.get("due_today_template")});
 if(!p.success||!validGraphApiVersion(p.data?.version))redirect("/app/settings?whatsapp=invalid");const {gym,userId}=await requireActiveGym();if(!canManage(gym.role))redirect("/app/settings?whatsapp=forbidden");let admin,cipher;try{admin=createAdminClient();cipher=encryptSecret(p.data.token);}catch{redirect("/app/settings?whatsapp=config");}
 let phone:any;try{phone=await whatsappGraphRequest(`/${encodeURIComponent(p.data.phoneId)}?fields=id,display_phone_number,verified_name`,p.data.token,p.data.version);if(phone?.id!==p.data.phoneId)throw new Error("phone mismatch");const account=await whatsappGraphRequest(`/${encodeURIComponent(p.data.waba)}/phone_numbers?fields=id`,p.data.token,p.data.version);if(!(account?.data??[]).some((x:any)=>x.id===p.data.phoneId))throw new Error("phone not in business account");}catch(e){if(e instanceof WhatsAppApiError&&(e.status===401||e.status===403))redirect("/app/settings?whatsapp=auth");redirect("/app/settings?whatsapp=verify");}
 const {error}=await admin.from("whatsapp_connections").upsert({gym_id:gym.id,provider:"meta_cloud",business_account_id:p.data.waba,phone_number_id:p.data.phoneId,display_phone_number:phone.display_phone_number??null,verified_name:phone.verified_name??null,encrypted_access_token:cipher,graph_api_version:p.data.version,language_code:p.data.language,pre_expiry_template:p.data.pre,due_today_template:p.data.due,status:"active",last_verified_at:new Date().toISOString(),created_by:userId,updated_at:new Date().toISOString()},{onConflict:"gym_id,provider"});if(error)redirect("/app/settings?whatsapp=save");revalidatePath("/app/settings");redirect("/app/settings?whatsapp=saved");
}
export async function setWhatsAppConsentAction(formData:FormData){const p=z.object({memberId:z.string().uuid(),optIn:z.enum(["yes","no"]),source:z.string().optional()}).safeParse({memberId:formData.get("member_id"),optIn:formData.get("opt_in"),source:formData.get("source")});if(!p.success||(p.data.optIn==="yes"&&!p.data.source))redirect("/app/members?error=consent");const {supabase,gym}=await requireActiveGym();const {error}=await supabase.rpc("set_member_whatsapp_consent_for_gym",{target_gym:gym.id,target_member:p.data.memberId,is_opted_in:p.data.optIn==="yes",consent_source:p.data.optIn==="yes"?p.data.source:"opt_out"});if(error)redirect("/app/members?error=consent");revalidatePath("/app/members");redirect("/app/members?consent=updated");}
export async function updateReminderTimeAction(formData:FormData){const time=z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).safeParse(formData.get("time"));if(!time.success)redirect("/app/settings?whatsapp=time_error");const {supabase,gym}=await requireActiveGym();const {error}=await supabase.rpc("update_gym_whatsapp_reminder_time",{target_gym:gym.id,local_send_time:time.data});if(error)redirect("/app/settings?whatsapp=time_error");revalidatePath("/app/settings");redirect("/app/settings?whatsapp=time_saved");}
export async function createPlatformCheckoutAction(formData:FormData){
 const p=z.object({productId:z.string().uuid(),requestKey:z.string().uuid()}).safeParse({productId:formData.get("product_id"),requestKey:formData.get("request_key")});if(!p.success)redirect("/app/billing?error=invalid");const {supabase,gym}=await requireActiveGym();
 const {data:product}=await supabase.from("platform_products").select("id,billing_type,name,price_paise").eq("id",p.data.productId).eq("active",true).single();if(!product)redirect("/app/billing?error=product");
 let admin;try{admin=createAdminClient();}catch{redirect("/app/billing?error=config");}
 const {data:reservation,error}=await supabase.rpc("create_platform_payment_request",{target_gym:gym.id,target_product:product.id,item_type:product.billing_type,request_key:p.data.requestKey});if(error||!reservation?.length)redirect("/app/billing?error=reserve");const pay=reservation[0];
 const {data:local}=await admin.from("platform_payment_links").select("id,status,short_url").eq("platform_payment_id",pay.platform_payment_id).single();if(local?.status==="created"&&local.short_url)redirect(local.short_url);if(!local||local.status!=="creating"||pay.is_new!==true)redirect("/app/billing?error=unknown");
 const keyId=process.env.PLATFORM_RAZORPAY_KEY_ID,keySecret=process.env.PLATFORM_RAZORPAY_KEY_SECRET;if(!keyId||!keySecret)redirect("/app/billing?error=config");
 let response:any;try{response=await razorpayRequest("/payment_links",{keyId,keySecret},{method:"POST",body:JSON.stringify({amount:Number(pay.amount_paise),currency:"INR",accept_partial:false,reference_id:pay.reference_id,description:`GymFlow ${product.name}`.slice(0,240),customer:{name:gym.name},notify:{sms:false,email:false},reminder_enable:false,expire_by:Math.floor(Date.now()/1000)+7*86400,notes:{gymflow_platform_payment_id:pay.platform_payment_id}})});}catch{await admin.from("platform_payment_links").update({status:"unknown"}).eq("id",local.id);redirect("/app/billing?error=provider");}
 const url=String(response.short_url??"");let safe=false;try{const u=new URL(url);safe=u.protocol==="https:"&&(u.hostname==="rzp.io"||u.hostname.endsWith(".razorpay.com"));}catch{}if(!safe||Number(response.amount)!==Number(pay.amount_paise)||response.currency!=="INR"||response.reference_id!==pay.reference_id){await admin.from("platform_payment_links").update({status:"needs_review"}).eq("id",local.id);redirect("/app/billing?error=provider_mismatch");}
 const {error:saveError}=await admin.from("platform_payment_links").update({provider_link_id:response.id,short_url:url,status:"created",updated_at:new Date().toISOString()}).eq("id",local.id);if(saveError)redirect("/app/billing?error=save");redirect(url);
}

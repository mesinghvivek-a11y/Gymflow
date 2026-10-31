import {timingSafeEqual} from "node:crypto";
import {NextRequest,NextResponse} from "next/server";
import {createAdminClient} from "@/lib/server/admin";
import {decryptSecret} from "@/lib/server/secret-vault";
import {razorpayRequest,RazorpayApiError} from "@/server/integrations/razorpay.js";
export const runtime="nodejs";export const dynamic="force-dynamic";export const maxDuration=30;
function auth(req:NextRequest){const secret=process.env.GYMFLOW_WORKER_SECRET||process.env.CRON_SECRET;const given=req.headers.get("authorization")?.replace(/^Bearer\s+/i,"")??"";if(!secret||!given)return false;const a=Buffer.from(secret),b=Buffer.from(given);return a.length===b.length&&timingSafeEqual(a,b);}
async function handler(req:NextRequest){if(!auth(req))return NextResponse.json({error:"Unauthorized"},{status:401});let admin;try{admin=createAdminClient();}catch{return NextResponse.json({error:"Worker configuration unavailable"},{status:503});}
 const {data:events,error}=await admin.rpc("claim_razorpay_webhook_events",{batch_size:5});if(error)return NextResponse.json({error:"Queue unavailable"},{status:503});const outcomes=[];
 for(const event of events??[]){try{
   if(Number(event.attempts)>8){await admin.from("webhook_events").update({status:"needs_review",last_error:"attempt_limit_exceeded"}).eq("id",event.id);outcomes.push("dead_lettered");continue;}
   const payload=event.payload;if(payload?.event!=="payment_link.paid"){await admin.from("webhook_events").update({status:"processed",processed_at:new Date().toISOString()}).eq("id",event.id);outcomes.push("ignored_event");continue;}
   const providerLinkId=payload?.payload?.payment_link?.entity?.id;if(typeof providerLinkId!=="string")throw new Error("payment_link_id_missing");
   const {data:link}=await admin.from("payment_links").select("id,gym_id,invoice_id,gateway_connection_id,reference_id,amount_paise,currency,status").eq("provider_link_id",providerLinkId).maybeSingle();
   if(!link)throw new Error("local_payment_link_not_found");
   const {data:connection}=await admin.from("gateway_connections").select("id,key_id,encrypted_key_secret").eq("id",link.gateway_connection_id).single();if(!connection)throw new Error("gateway_connection_not_found");
   const credentials={keyId:connection.key_id,keySecret:decryptSecret(connection.encrypted_key_secret)};
   const remote:any=await razorpayRequest(`/payment_links/${encodeURIComponent(providerLinkId)}`,credentials);
   if(remote.id!==providerLinkId||remote.reference_id!==link.reference_id||remote.currency!=="INR"||remote.status!=="paid"||Number(remote.amount)!==Number(link.amount_paise)||Number(remote.amount_paid)!==Number(link.amount_paise)||Number(remote.amount_due)!==0)throw new Error("payment_link_provider_mismatch");
   const list:any=await razorpayRequest(`/payment_links/${encodeURIComponent(providerLinkId)}/payments`,credentials);
   const candidates=Array.isArray(list?.items)?list.items:Array.isArray(list?.payments)?list.payments:Array.isArray(list?.data)?list.data:[];
   const captured=candidates.filter((p:any)=>p?.status==="captured"&&typeof p.id==="string"&&Number(p.amount)===Number(link.amount_paise));
   if(captured.length!==1)throw new Error("captured_payment_not_unique");
   const payment:any=await razorpayRequest(`/payments/${encodeURIComponent(captured[0].id)}`,credentials);
   if(payment.status!=="captured"||payment.currency!=="INR"||Number(payment.amount)!==Number(link.amount_paise))throw new Error("captured_payment_mismatch");
   const {error:applyError}=await admin.rpc("record_verified_razorpay_payment",{target_payment_link:link.id,target_gateway_connection:connection.id,provider_payment_reference:payment.id,received_amount_paise:Number(payment.amount),captured_at:payment.created_at?new Date(payment.created_at*1000).toISOString():new Date().toISOString()});
   if(applyError)throw new Error(applyError.message);
   await admin.from("webhook_events").update({status:"processed",processed_at:new Date().toISOString(),last_error:null}).eq("id",event.id);outcomes.push("processed");
  }catch(error){const reason=error instanceof Error?error.message.slice(0,250):"worker_error";const terminal=error instanceof RazorpayApiError&&error.status>=400&&error.status<500&&error.status!==429;
   await admin.from("webhook_events").update({status:terminal||Number(event.attempts)>=8?"needs_review":"queued",last_error:reason}).eq("id",event.id);
   outcomes.push(terminal?"needs_review":"retry");
  }}
 return NextResponse.json({ok:true,claimed:events?.length??0,outcomes},{headers:{"Cache-Control":"no-store"}});
}
export async function GET(req:NextRequest){return handler(req);}export async function POST(req:NextRequest){return handler(req);}

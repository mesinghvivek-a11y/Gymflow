import {createHash} from "node:crypto";
import {NextRequest,NextResponse} from "next/server";
import {createAdminClient} from "@/lib/server/admin";
import {verifyRazorpayWebhookSignature,razorpayRequest} from "@/server/integrations/razorpay.js";
export const runtime="nodejs";export const dynamic="force-dynamic";
const fail=(message:string,status:number)=>NextResponse.json({error:message},{status,headers:{"Cache-Control":"no-store"}});
export async function POST(req:NextRequest){
 const raw=Buffer.from(await req.arrayBuffer());if(!raw.length||raw.length>1024*1024)return fail("Invalid payload",413);
 const keyId=process.env.PLATFORM_RAZORPAY_KEY_ID,keySecret=process.env.PLATFORM_RAZORPAY_KEY_SECRET,webhookSecret=process.env.PLATFORM_RAZORPAY_WEBHOOK_SECRET;
 if(!keyId||!keySecret||!webhookSecret)return fail("Platform billing webhook not configured",503);
 if(!verifyRazorpayWebhookSignature(raw,req.headers.get("x-razorpay-signature")??"",webhookSecret))return fail("Invalid signature",401);
 let payload:any;try{payload=JSON.parse(raw.toString("utf8"));}catch{return fail("Invalid JSON",400);}if(typeof payload?.event!=="string")return fail("Invalid event envelope",400);
 let admin;try{admin=createAdminClient();}catch{return fail("Database unavailable",503);}
 const eventId=req.headers.get("x-razorpay-event-id")||createHash("sha256").update(raw).digest("hex");
 const inserted=await admin.from("platform_webhook_events").upsert({event_id:eventId,payload,status:"processing"},{onConflict:"event_id",ignoreDuplicates:true});if(inserted.error)return fail("Could not persist event",500);
 if(payload.event!=="payment_link.paid"){await admin.from("platform_webhook_events").update({status:"processed",processed_at:new Date().toISOString()}).eq("event_id",eventId);return NextResponse.json({received:true,ignored:true});}
 try{
  const linkId=payload?.payload?.payment_link?.entity?.id;if(typeof linkId!=="string")throw new Error("payment_link_id_missing");
  const {data:local}=await admin.from("platform_payment_links").select("id,platform_payment_id,reference_id").eq("provider_link_id",linkId).maybeSingle();if(!local)throw new Error("platform_payment_link_not_found");
  const credentials={keyId,keySecret};const remote:any=await razorpayRequest(`/payment_links/${encodeURIComponent(linkId)}`,credentials);
  if(remote.id!==linkId||remote.reference_id!==local.reference_id||remote.currency!=="INR"||remote.status!=="paid"||Number(remote.amount)!==Number(remote.amount_paid)||Number(remote.amount_due)!==0)throw new Error("platform_payment_link_mismatch");
  const payments:any=await razorpayRequest(`/payment_links/${encodeURIComponent(linkId)}/payments`,credentials);const items=Array.isArray(payments.items)?payments.items:[];const captures=items.filter((p:any)=>p.status==="captured"&&Number(p.amount)===Number(remote.amount));if(captures.length!==1)throw new Error("platform_capture_not_unique");
  const payment:any=await razorpayRequest(`/payments/${encodeURIComponent(captures[0].id)}`,credentials);if(payment.status!=="captured"||payment.currency!=="INR"||Number(payment.amount)!==Number(remote.amount))throw new Error("platform_capture_mismatch");
  const {error}=await admin.rpc("apply_verified_platform_payment",{target_payment:local.platform_payment_id,provider_payment_reference:payment.id,received_amount_paise:Number(payment.amount),paid_time:payment.created_at?new Date(payment.created_at*1000).toISOString():new Date().toISOString()});if(error)throw new Error(error.message);
  await admin.from("platform_webhook_events").update({status:"processed",processed_at:new Date().toISOString(),last_error:null}).eq("event_id",eventId);
  return NextResponse.json({received:true,processed:true});
 }catch(error){const reason=error instanceof Error?error.message.slice(0,250):"processing_error";await admin.from("platform_webhook_events").update({status:"needs_review",last_error:reason}).eq("event_id",eventId);return NextResponse.json({received:true,needsReview:true},{status:200});}
}

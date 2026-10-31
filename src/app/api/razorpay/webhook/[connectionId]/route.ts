import {createHash} from "node:crypto";
import {NextRequest,NextResponse} from "next/server";
import {createAdminClient} from "@/lib/server/admin";
import {decryptSecret} from "@/lib/server/secret-vault";
import {verifyRazorpayWebhookSignature} from "@/server/integrations/razorpay.js";
export const runtime="nodejs";export const dynamic="force-dynamic";
const fail=(message:string,status:number)=>NextResponse.json({error:message},{status,headers:{"Cache-Control":"no-store"}});
export async function POST(req:NextRequest,{params}:{params:Promise<{connectionId:string}>}){
 const {connectionId}=await params;if(!/^[0-9a-f-]{36}$/i.test(connectionId))return fail("Not found",404);
 const raw=Buffer.from(await req.arrayBuffer());if(raw.length<1||raw.length>1024*1024)return fail("Invalid payload size",413);
 let admin;try{admin=createAdminClient();}catch{return fail("Webhook not configured",503);}
 const {data:connection}=await admin.from("gateway_connections").select("id,encrypted_webhook_secret").eq("id",connectionId).maybeSingle();if(!connection)return fail("Not found",404);
 let secret;try{secret=decryptSecret(connection.encrypted_webhook_secret);}catch{return fail("Webhook secret unavailable",503);}
 if(!verifyRazorpayWebhookSignature(raw,req.headers.get("x-razorpay-signature")??"",secret))return fail("Invalid signature",401);
 let payload:any;try{payload=JSON.parse(raw.toString("utf8"));}catch{return fail("Invalid JSON",400);}
 if(!payload||typeof payload.event!=="string")return fail("Invalid event envelope",400);
 const header=req.headers.get("x-razorpay-event-id");const eventId=header&&/^[\w.-]{1,128}$/.test(header)?header:createHash("sha256").update(raw).digest("hex");
 const {error}=await admin.rpc("enqueue_razorpay_webhook_event",{target_connection:connection.id,target_event_id:eventId,event_payload:payload});
 if(error)return fail("Verified event could not be durably queued",500);
 return NextResponse.json({received:true,queued:true},{status:200,headers:{"Cache-Control":"no-store"}});
}

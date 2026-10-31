import {timingSafeEqual} from "node:crypto";
import {NextRequest,NextResponse} from "next/server";
import {createAdminClient} from "@/lib/server/admin";
import {runWhatsAppReminderBatch} from "@/server/integrations/whatsapp-worker";
export const runtime="nodejs";export const dynamic="force-dynamic";export const maxDuration=30;
function authorized(req:NextRequest){const secret=process.env.GYMFLOW_WORKER_SECRET||process.env.CRON_SECRET;const supplied=req.headers.get("authorization")?.replace(/^Bearer\s+/i,"")??"";if(!secret||!supplied)return false;const a=Buffer.from(secret),b=Buffer.from(supplied);return a.length===b.length&&timingSafeEqual(a,b);}
async function handler(req:NextRequest){if(!authorized(req))return NextResponse.json({error:"Unauthorized"},{status:401});try{const admin=createAdminClient();const result=await runWhatsAppReminderBatch(admin,10);return NextResponse.json({ok:true,...result},{headers:{"Cache-Control":"no-store"}});}catch{return NextResponse.json({error:"WhatsApp worker unavailable"},{status:503});}}
export async function GET(req:NextRequest){return handler(req);}export async function POST(req:NextRequest){return handler(req);}

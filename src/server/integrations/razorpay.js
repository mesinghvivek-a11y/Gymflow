import { createHmac, timingSafeEqual } from "node:crypto";
export class RazorpayApiError extends Error { constructor(message,status,code=null){super(message);this.name="RazorpayApiError";this.status=status;this.code=code;} }
function safePath(path){return typeof path==="string"&&path.startsWith("/")&&!path.startsWith("//")&&!path.includes("..")&&/^[\/A-Za-z0-9_.?=&%-]+$/.test(path);}
export async function razorpayRequest(path,credentials,options={}){
 if(!safePath(path)) throw new Error("Unsafe Razorpay API path");
 if(!credentials?.keyId||!credentials?.keySecret) throw new Error("Razorpay credentials are missing");
 const auth=Buffer.from(`${credentials.keyId}:${credentials.keySecret}`).toString("base64");
 const res=await fetch(`https://api.razorpay.com/v1${path}`,{...options,cache:"no-store",headers:{Authorization:`Basic ${auth}`,Accept:"application/json",...(options.body?{"Content-Type":"application/json"}:{}),...(options.headers??{})},signal:options.signal??AbortSignal.timeout(12000)});
 let data;try{data=await res.json();}catch{throw new RazorpayApiError("Razorpay returned invalid JSON",res.status);}
 if(!res.ok) throw new RazorpayApiError(String(data?.error?.description??"Razorpay request failed").slice(0,300),res.status,data?.error?.code??null);
 return data;
}
export function verifyRazorpayWebhookSignature(rawBody,signature,secret){
 if(!Buffer.isBuffer(rawBody)||typeof signature!=="string"||!/^[a-f0-9]{64}$/i.test(signature)||typeof secret!=="string"||secret.length<8)return false;
 const expected=createHmac("sha256",secret).update(rawBody).digest(),given=Buffer.from(signature,"hex");
 return given.length===expected.length&&timingSafeEqual(expected,given);
}

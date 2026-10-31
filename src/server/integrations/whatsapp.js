import {createHmac,timingSafeEqual} from "node:crypto";
export class WhatsAppApiError extends Error{constructor(message,status,code=null){super(message);this.name="WhatsAppApiError";this.status=status;this.code=code;}}
export function validGraphApiVersion(v){return typeof v==="string"&&/^v\d{1,3}\.\d{1,2}$/.test(v);}
function safePath(p){return typeof p==="string"&&p.startsWith("/")&&!p.startsWith("//")&&!p.includes("..")&&/^[\/A-Za-z0-9_.?=&%-]+$/.test(p);}
export async function whatsappGraphRequest(path,token,version,options={}){
 if(!safePath(path)||!validGraphApiVersion(version)||typeof token!=="string"||token.length<20)throw new Error("Invalid WhatsApp API request");
 const res=await fetch(`https://graph.facebook.com/${version}${path}`,{...options,cache:"no-store",headers:{Authorization:`Bearer ${token}`,Accept:"application/json",...(options.body?{"Content-Type":"application/json"}:{}),...(options.headers??{})},signal:options.signal??AbortSignal.timeout(12000)});
 let data;try{data=await res.json();}catch{throw new WhatsAppApiError("Meta Graph API returned invalid JSON",res.status);}
 if(!res.ok)throw new WhatsAppApiError(String(data?.error?.message??"WhatsApp API request failed").slice(0,300),res.status,data?.error?.code==null?null:String(data.error.code));
 return data;
}
export function verifyWhatsAppAppSignature(raw,signature,secret){if(!Buffer.isBuffer(raw)||typeof signature!=="string"||!/^sha256=[a-f0-9]{64}$/i.test(signature)||typeof secret!=="string"||secret.length<16)return false;const expected=createHmac("sha256",secret).update(raw).digest(),given=Buffer.from(signature.slice(7),"hex");return given.length===expected.length&&timingSafeEqual(expected,given);}
export function formatWhatsAppExpiry(value,timezone){return new Intl.DateTimeFormat("en-IN",{day:"numeric",month:"long",year:"numeric",timeZone:timezone}).format(new Date(value));}

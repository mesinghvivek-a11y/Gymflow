import {randomUUID} from "node:crypto";
import {CircleDollarSign,ShieldCheck} from "lucide-react";
import {requireActiveGym} from "@/lib/workspace";
import {createPlatformCheckoutAction} from "@/server/actions/integrations";
import {SubmitButton} from "@/components/submit-button";
export const dynamic="force-dynamic";
function money(paise:number){return new Intl.NumberFormat("en-IN",{style:"currency",currency:"INR"}).format(paise/100);}
export default async function BillingPage({searchParams}:{searchParams:Promise<{error?:string}>}){
 const [{supabase,gym},params]=await Promise.all([requireActiveGym(),searchParams]);
 const [{data:products}, {data:subs}, {data:licences}] = await Promise.all([
  supabase.from("platform_products").select("id,code,name,description,billing_type,price_paise,interval_months,entitlements").eq("active",true).order("display_order"),
  supabase.from("platform_subscriptions").select("id,status,current_period_start,current_period_end,product:platform_products(name)").eq("gym_id",gym.id).order("created_at",{ascending:false}).limit(5),
  supabase.from("platform_licences").select("id,licence_code,status,granted_at,product:platform_products(name)").eq("gym_id",gym.id).eq("status","active").limit(5)
 ]);
 const {data:entitlements}=await supabase.rpc("gymflow_entitlements",{target_gym:gym.id});
 const errors:Record<string,string>={config:"Platform Razorpay credentials have not been configured by GymFlow.",reserve:"Could not prepare the checkout. Try again.",provider:"The payment provider could not create the link. No payment has been marked successful.",provider_mismatch:"The provider response did not match the requested amount. It needs review.",unknown:"Payment link creation has an uncertain state. Contact support before retrying.",save:"Payment link was created but could not be saved locally. Contact support."};
 return <>
  <div className="page-head"><div><div className="eyebrow">Platform account</div><h1>GymFlow billing</h1><p>This bill is for using GymFlow. It is separate from fees collected from your gym members.</p></div></div>
  {params.error&&<div className="error-notice">{errors[params.error]??"Unable to start checkout."}</div>}
  <section className="panel"><div className="panel-head"><div><h2>Current access</h2><p className="muted" style={{marginTop:5}}>Entitlements are applied on the server after verified platform billing.</p></div><span className="metric-icon"><ShieldCheck size={17}/></span></div><div className="settings-grid"><div><div className="eyebrow">Billing source</div><strong>{entitlements?.billingSource??"Not configured"}</strong></div><div><div className="eyebrow">Access mode</div><strong>{entitlements?.access??"read_only"}</strong></div></div></section>
  <section style={{marginTop:22}}><div className="panel-head"><div><h2>Available plans and licences</h2><p className="muted" style={{marginTop:5}}>One-time licence covers only its disclosed software scope; hosting, messaging and support terms are separate.</p></div></div><div className="card-grid">{(products??[]).map((product:any)=><article className="plan-card" key={product.id}><div className="eyebrow">{product.billing_type==="subscription"?"Recurring subscription":"One-time licence"}</div><strong style={{fontSize:16,marginTop:7}}>{product.name}</strong><p className="muted">{product.description}</p><div className="plan-price">{money(product.price_paise)}{product.interval_months?<span style={{fontSize:11,color:"var(--muted)",fontWeight:500}}> / {product.interval_months} month(s)</span>:null}</div><form action={createPlatformCheckoutAction}><input type="hidden" name="product_id" value={product.id}/><input type="hidden" name="request_key" value={randomUUID()}/><SubmitButton className="primary-btn lime" pendingText="Preparing checkout…">Continue to secure payment</SubmitButton></form></article>)}</div></section>
  <section className="panel" style={{marginTop:22}}><div className="panel-head"><h2>Subscription and licence history</h2><span className="metric-icon"><CircleDollarSign size={17}/></span></div>{!(subs?.length||licences?.length)?<div className="empty-state">No GymFlow subscription or licence purchases yet.</div>:<div className="table-wrap"><table><thead><tr><th>Type</th><th>Product</th><th>Status / code</th><th>Period / granted</th></tr></thead><tbody>{(subs??[]).map((s:any)=><tr key={s.id}><td>Subscription</td><td>{s.product?.name??"Plan"}</td><td>{s.status}</td><td>{s.current_period_end?new Date(s.current_period_end).toLocaleDateString("en-IN"):"—"}</td></tr>)}{(licences??[]).map((l:any)=><tr key={l.id}><td>Perpetual licence</td><td>{l.product?.name??"Licence"}</td><td>{l.licence_code}</td><td>{new Date(l.granted_at).toLocaleDateString("en-IN")}</td></tr>)}</tbody></table></div>}</section>
 </>;
}

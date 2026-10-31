import { randomUUID } from "node:crypto";
import { Plus } from "lucide-react";
import { requireActiveGym } from "@/lib/workspace";
import { createMemberAction, updateMemberAction, setMemberArchivedAction } from "@/server/actions/members";
import { setWhatsAppConsentAction } from "@/server/actions/integrations";
import { SubmitButton } from "@/components/submit-button";
import { MemberDirectory } from "@/components/member-directory";

export const dynamic = "force-dynamic";

export default async function MembersPage({ searchParams }: { searchParams: Promise<{ error?: string; created?: string; consent?: string; updated?: string; archived?: string; restored?: string }> }) {
  const [{ supabase, gym }, params] = await Promise.all([requireActiveGym(), searchParams]);
  const { data: members, error } = await supabase
    .from("members")
    .select("id,member_number,full_name,phone_e164,address,created_at,whatsapp_opt_in,archived_at")
    .eq("gym_id", gym.id)
    .order("created_at", { ascending: false })
    .limit(500);

  const messages: Record<string, string> = {
    invalid: "Enter a member name and valid mobile number.",
    phone: "Enter a valid Indian mobile number or international number in E.164 format.",
    create: "Member could not be created.",
    update: "Member could not be updated.",
    archive: "Member status could not be changed.",
    forbidden: "You do not have permission to change this member.",
    exhausted: "This gym has used all available five-digit IDs. Contact support for a larger ID format.",
    consent: "Record a valid consent source before opting a member in.",
  };

  return <>
    <div className="page-head">
      <div><div className="eyebrow">Member directory</div><h1>Members</h1><p>Create member profiles, update contact details and retain their membership history together.</p></div>
      <span className="topbar-date">{members?.filter((member: any) => !member.archived_at).length ?? 0} active</span>
    </div>
    {params.error && <div className="error-notice">{messages[params.error] ?? "Something went wrong."}</div>}
    {params.created && <div className="success-notice">Member created. Their five-digit gym ID was assigned automatically.</div>}
    {params.updated && <div className="success-notice">Member details updated.</div>}
    {params.archived && <div className="success-notice">Member archived. Their payment and membership history has been retained.</div>}
    {params.restored && <div className="success-notice">Member restored to the active directory.</div>}
    {params.consent && <div className="success-notice">WhatsApp consent setting updated.</div>}
    <section className="form-panel">
      <div className="panel-head"><div><h2>Add a member</h2><p className="muted" style={{ marginTop: 4 }}>IDs are five digits, unique within this gym and never reused.</p></div><span className="metric-icon"><Plus size={17} /></span></div>
      <form action={createMemberAction} className="form-row">
        <input type="hidden" name="request_key" value={randomUUID()} />
        <div className="inline-field"><label htmlFor="name">Full name</label><input id="name" name="name" required maxLength={120} /></div>
        <div className="inline-field"><label htmlFor="phone">Mobile number</label><input id="phone" name="phone" type="tel" placeholder="98765 43210" required maxLength={20} /></div>
        <div className="inline-field"><label htmlFor="address">Address (optional)</label><input id="address" name="address" maxLength={500} /></div>
        <SubmitButton className="primary-btn lime" pendingText="Adding member…">Add member <Plus size={14} /></SubmitButton>
      </form>
    </section>
    {error ? <div className="error-notice">Unable to load members.</div> : <MemberDirectory members={members ?? []} timezone={gym.timezone} updateAction={updateMemberAction} archiveAction={setMemberArchivedAction} consentAction={setWhatsAppConsentAction} />}
  </>;
}

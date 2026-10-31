"use client";

import { useMemo, useState } from "react";
import { Archive, Check, Pencil, Search, RotateCcw, Users } from "lucide-react";
import { SubmitButton } from "@/components/submit-button";

type Member = {
  id: string;
  member_number: string;
  full_name: string;
  phone_e164: string;
  address: string | null;
  created_at: string;
  whatsapp_opt_in: boolean;
  archived_at: string | null;
};
type FormAction = (formData: FormData) => void | Promise<void>;

type Props = {
  members: Member[];
  timezone: string;
  updateAction: FormAction;
  archiveAction: FormAction;
  consentAction: FormAction;
};

export function MemberDirectory({ members, timezone, updateAction, archiveAction, consentAction }: Props) {
  const [query, setQuery] = useState("");
  const [view, setView] = useState<"active" | "archived">("active");
  const filtered = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase("en-IN");
    return members.filter((member) => {
      if (view === "active" ? Boolean(member.archived_at) : !member.archived_at) return false;
      if (!needle) return true;
      return [member.full_name, member.member_number, member.phone_e164]
        .some((value) => value.toLocaleLowerCase("en-IN").includes(needle));
    });
  }, [members, query, view]);
  const activeCount = members.filter((member) => !member.archived_at).length;
  const archivedCount = members.length - activeCount;

  return (
    <section className="panel">
      <div className="panel-head member-directory-head">
        <div><h2>Member directory</h2><p className="muted" style={{ marginTop: 5 }}>Search is instant and runs locally on the records loaded for this gym.</p></div>
        <span className="metric-icon"><Users size={17} /></span>
      </div>
      <div className="directory-toolbar">
        <label className="directory-search">
          <Search size={16} aria-hidden="true" />
          <input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search name, 5-digit ID or phone" aria-label="Search members" />
        </label>
        <div className="directory-tabs" role="group" aria-label="Member status filter">
          <button type="button" className={view === "active" ? "selected" : ""} onClick={() => setView("active")}>Active <span>{activeCount}</span></button>
          <button type="button" className={view === "archived" ? "selected" : ""} onClick={() => setView("archived")}>Archived <span>{archivedCount}</span></button>
        </div>
      </div>
      <div className="directory-result-count" aria-live="polite">Showing {filtered.length} of {view === "active" ? activeCount : archivedCount} {view} members</div>
      {!filtered.length ? (
        <div className="empty-state"><Users size={23} /><strong>{query ? "No matching members" : view === "active" ? "No active members" : "No archived members"}</strong>{query ? "Try another name, member ID or phone number." : view === "active" ? "Add your first member above." : "Archived members will appear here."}</div>
      ) : (
        <div className="table-wrap">
          <table>
            <thead><tr><th>Member</th><th>Member ID</th><th>Phone</th><th>Joined</th><th>WhatsApp permission</th><th>Manage</th></tr></thead>
            <tbody>
              {filtered.map((member) => (
                <tr key={member.id}>
                  <td><div className="member-cell"><span className="due-avatar">{member.full_name[0]?.toUpperCase()}</span>{member.full_name}</div></td>
                  <td><span className="member-id">{member.member_number}</span></td>
                  <td>{member.phone_e164}</td>
                  <td>{new Intl.DateTimeFormat("en-IN", { dateStyle: "medium", timeZone: timezone }).format(new Date(member.created_at))}</td>
                  <td>
                    {view === "active" ? (
                      <form className="consent-inline-form" action={consentAction}>
                        <input type="hidden" name="member_id" value={member.id} />
                        <select name="opt_in" defaultValue={member.whatsapp_opt_in ? "yes" : "no"} aria-label="WhatsApp reminder consent">
                          <option value="no">Opted out</option><option value="yes">Opted in</option>
                        </select>
                        <select name="source" defaultValue="" aria-label="Consent source">
                          <option value="">Source…</option><option value="signed_form">Signed form</option><option value="in_person_verbal">In person</option><option value="website_form">Website form</option><option value="recorded_message">Recorded message</option><option value="other">Other</option>
                        </select>
                        <SubmitButton className="small-btn" pendingText="Saving…"><Check size={12} /> Save</SubmitButton>
                      </form>
                    ) : <span className="muted">—</span>}
                  </td>
                  <td>
                    {view === "active" ? (
                      <div className="member-actions">
                        <details className="member-edit-details">
                          <summary className="small-btn"><Pencil size={12} /> Edit</summary>
                          <form action={updateAction} className="member-edit-form">
                            <input type="hidden" name="member_id" value={member.id} />
                            <label>Name<input name="name" defaultValue={member.full_name} required maxLength={120} /></label>
                            <label>Mobile<input name="phone" defaultValue={member.phone_e164} required maxLength={20} /></label>
                            <label>Address<input name="address" defaultValue={member.address ?? ""} maxLength={500} placeholder="Optional address" /></label>
                            <SubmitButton className="primary-btn lime" pendingText="Updating…">Save changes</SubmitButton>
                          </form>
                        </details>
                        <form action={archiveAction} onSubmit={(event) => { if (!window.confirm(`Archive ${member.full_name}? Their history will be retained, but they will leave the active directory and WhatsApp reminders will stop while archived.`)) event.preventDefault(); }}>
                          <input type="hidden" name="member_id" value={member.id} /><input type="hidden" name="archived" value="yes" />
                          <SubmitButton className="small-btn danger-btn" pendingText="Archiving…"><Archive size={12} /> Archive</SubmitButton>
                        </form>
                      </div>
                    ) : (
                      <form action={archiveAction}>
                        <input type="hidden" name="member_id" value={member.id} /><input type="hidden" name="archived" value="no" />
                        <SubmitButton className="small-btn" pendingText="Restoring…"><RotateCcw size={12} /> Restore</SubmitButton>
                      </form>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

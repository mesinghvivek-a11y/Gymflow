"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { requireActiveGym } from "@/lib/workspace";
import { normalizeIndianPhone } from "@/domain/phone.js";

const createSchema = z.object({
  name: z.string().trim().min(1).max(120),
  phone: z.string().trim().min(8).max(20),
  address: z.string().trim().max(500).optional(),
  requestKey: z.string().uuid(),
});
const updateSchema = z.object({
  memberId: z.string().uuid(),
  name: z.string().trim().min(1).max(120),
  phone: z.string().trim().min(8).max(20),
  address: z.string().trim().max(500).optional(),
});

export async function createMemberAction(formData: FormData) {
  const parsed = createSchema.safeParse({
    name: formData.get("name"), phone: formData.get("phone"),
    address: formData.get("address") || "", requestKey: formData.get("request_key"),
  });
  if (!parsed.success) redirect("/app/members?error=invalid");
  const phone = normalizeIndianPhone(parsed.data.phone);
  if (!phone) redirect("/app/members?error=phone");
  const { supabase, gym } = await requireActiveGym();
  const { error } = await supabase.rpc("create_member_for_gym", {
    target_gym: gym.id, member_name: parsed.data.name, member_phone: phone,
    member_address: parsed.data.address || null, p_request_key: parsed.data.requestKey,
  });
  if (error) redirect(`/app/members?error=${error.message.includes("member_id_space_exhausted") ? "exhausted" : "create"}`);
  revalidatePath("/app/members");
  revalidatePath("/app");
  redirect("/app/members?created=1");
}

export async function updateMemberAction(formData: FormData) {
  const parsed = updateSchema.safeParse({
    memberId: formData.get("member_id"), name: formData.get("name"),
    phone: formData.get("phone"), address: formData.get("address") || "",
  });
  if (!parsed.success) redirect("/app/members?error=invalid");
  const phone = normalizeIndianPhone(parsed.data.phone);
  if (!phone) redirect("/app/members?error=phone");
  const { supabase, gym } = await requireActiveGym();
  const { error } = await supabase.rpc("update_member_for_gym", {
    target_gym: gym.id, target_member: parsed.data.memberId,
    member_name: parsed.data.name, member_phone: phone,
    member_address: parsed.data.address || null,
  });
  if (error) redirect(`/app/members?error=${error.message.includes("permission_denied") ? "forbidden" : "update"}`);
  revalidatePath("/app/members");
  revalidatePath("/app");
  redirect("/app/members?updated=1");
}

export async function setMemberArchivedAction(formData: FormData) {
  const parsed = z.object({ memberId: z.string().uuid(), archived: z.enum(["yes", "no"]) })
    .safeParse({ memberId: formData.get("member_id"), archived: formData.get("archived") });
  if (!parsed.success) redirect("/app/members?error=invalid");
  const { supabase, gym } = await requireActiveGym();
  const { error } = await supabase.rpc("set_member_archived_for_gym", {
    target_gym: gym.id, target_member: parsed.data.memberId,
    should_archive: parsed.data.archived === "yes",
  });
  if (error) redirect(`/app/members?error=${error.message.includes("permission_denied") ? "forbidden" : "archive"}`);
  revalidatePath("/app/members");
  revalidatePath("/app/dues");
  redirect(parsed.data.archived === "yes" ? "/app/members?archived=1" : "/app/members?restored=1");
}

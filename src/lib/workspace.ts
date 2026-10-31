import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type GymSummary = { id: string; name: string; timezone: string; role: string };

/**
 * Request-scoped identity lookup. Layouts and pages can both ask for the
 * verified user without repeating the same Supabase auth work in one render.
 */
export const getVerifiedUser = cache(async function getVerifiedUser() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims();
  if (error || !data?.claims?.sub) redirect("/login");
  return {
    supabase,
    userId: String(data.claims.sub),
    email: String(data.claims.email ?? ""),
  };
});

/** Resolve memberships and gym metadata in one PostgREST request. */
export async function getUserGyms(supabase: any, userId: string): Promise<GymSummary[]> {
  const { data: rows, error } = await supabase
    .from("gym_users")
    .select("role,created_at,gym:gyms!gym_users_gym_id_fkey!inner(id,name,timezone)")
    .eq("user_id", userId)
    .order("created_at");

  if (error) throw new Error("Could not load gym access");
  return (rows ?? []).flatMap((row: any) => {
    const related = Array.isArray(row.gym) ? row.gym[0] : row.gym;
    return related
      ? [{ id: related.id, name: related.name, timezone: related.timezone, role: row.role }]
      : [];
  });
}

/** Shared by the workspace layout and the active page during a render. */
export const requireActiveGym = cache(async function requireActiveGym() {
  const { supabase, userId, email } = await getVerifiedUser();
  const gyms = await getUserGyms(supabase, userId);
  if (!gyms.length) redirect("/onboarding");
  return { supabase, userId, email, gym: gyms[0], gyms };
});

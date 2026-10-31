/** All date operations use UTC instants; gym-local scheduling belongs to the server DB. */
export function addCalendarMonths(date, months) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime()) || !Number.isInteger(months)) throw new Error("Invalid date or month count");
  const day = date.getUTCDate();
  const result = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + months, 1,
    date.getUTCHours(), date.getUTCMinutes(), date.getUTCSeconds(), date.getUTCMilliseconds()));
  const lastDay = new Date(Date.UTC(result.getUTCFullYear(), result.getUTCMonth() + 1, 0)).getUTCDate();
  result.setUTCDate(Math.min(day, lastDay));
  return result;
}
export function isMembershipActive(startsAt, endsAt, now) {
  return startsAt.getTime() <= now.getTime() && now.getTime() < endsAt.getTime();
}
export function renewalStart(currentEndsAt, now, selectedStart = now) {
  return currentEndsAt.getTime() > now.getTime() ? new Date(currentEndsAt) : new Date(selectedStart);
}
export function deriveMembershipStatus({ startsAt, endsAt, now, paused = false, cancelled = false, pendingPayment = false, dueSoonDays = 3 }) {
  if (cancelled) return "cancelled";
  if (paused) return "paused";
  if (pendingPayment) return "pending_payment";
  if (now < startsAt) return "pending_payment";
  const remaining = endsAt.getTime() - now.getTime();
  if (remaining <= 0) return "expired";
  if (remaining <= 86_400_000) return "due_today";
  if (remaining <= dueSoonDays * 86_400_000) return "due_soon";
  return "active";
}

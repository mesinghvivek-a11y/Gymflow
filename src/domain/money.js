/** Convert rupees to integer paise; persist only integer paise. */
export function rupeesToPaise(value) {
  const amount = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
  if (typeof amount !== "number" || !Number.isFinite(amount) || amount < 0) throw new Error("Invalid INR amount");
  const paise = Math.round((amount + Number.EPSILON) * 100);
  if (!Number.isSafeInteger(paise)) throw new Error("Amount exceeds safe integer range");
  return paise;
}
export function formatINR(paise) {
  if (!Number.isSafeInteger(paise) || paise < 0) throw new Error("Amount must be non-negative integer paise");
  return new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 2 }).format(paise / 100);
}

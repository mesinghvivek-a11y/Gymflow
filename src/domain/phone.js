/** Normalize common Indian mobile input to E.164. International input must include +country code. */
export function normalizeIndianPhone(input) {
  if (typeof input !== "string") return null;
  const value = input.trim().replace(/[\s()-]/g, "");
  if (/^\+[1-9]\d{7,14}$/.test(value)) return value;
  const digits = value.replace(/\D/g, "");
  if (/^[6-9]\d{9}$/.test(digits)) return `+91${digits}`;
  if (/^91[6-9]\d{9}$/.test(digits)) return `+${digits}`;
  if (/^0[6-9]\d{9}$/.test(digits)) return `+91${digits.slice(1)}`;
  return null;
}

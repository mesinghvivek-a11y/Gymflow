export const MEMBER_ID_MIN = 10000;
export const MEMBER_ID_MAX = 99999;
export function isValidMemberNumber(value) { return /^\d{5}$/.test(value); }
export function nextCandidate(used, start = MEMBER_ID_MIN) {
  const span = MEMBER_ID_MAX - MEMBER_ID_MIN + 1;
  for (let offset = 0; offset < span; offset++) {
    const candidate = MEMBER_ID_MIN + ((start - MEMBER_ID_MIN + offset + span) % span);
    if (!used.has(candidate)) return candidate;
  }
  return null;
}

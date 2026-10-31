import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
function keyFromEnv() {
  const raw = process.env.GYMFLOW_ENCRYPTION_KEY ?? "";
  if (!/^[a-f0-9]{64}$/i.test(raw)) throw new Error("GYMFLOW_ENCRYPTION_KEY must be 32 bytes encoded as 64 hex characters");
  return Buffer.from(raw, "hex");
}
export function encryptSecret(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 8192) throw new Error("Invalid secret value");
  const key=keyFromEnv(), iv=randomBytes(12), cipher=createCipheriv("aes-256-gcm",key,iv);
  const encrypted=Buffer.concat([cipher.update(value,"utf8"),cipher.final()]);
  return `v1.${iv.toString("base64url")}.${cipher.getAuthTag().toString("base64url")}.${encrypted.toString("base64url")}`;
}
export function decryptSecret(payload) {
  if (typeof payload !== "string") throw new Error("Invalid encrypted secret");
  const [version,ivText,tagText,dataText,...extra]=payload.split(".");
  if(version!=="v1"||!ivText||!tagText||!dataText||extra.length) throw new Error("Malformed encrypted secret");
  const iv=Buffer.from(ivText,"base64url"), tag=Buffer.from(tagText,"base64url"), data=Buffer.from(dataText,"base64url");
  if(iv.length!==12||tag.length!==16||data.length>8192) throw new Error("Malformed encrypted secret");
  const decipher=createDecipheriv("aes-256-gcm",keyFromEnv(),iv); decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(data),decipher.final()]).toString("utf8");
}

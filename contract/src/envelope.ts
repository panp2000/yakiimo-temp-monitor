// Yakiimo Ingest Contract — Envelope (HMAC 認証層)

export const CONTRACT_VERSION = 1;

export const TIMESTAMP_HEADER = "X-Yakiimo-Timestamp";
export const SIGNATURE_HEADER = "X-Yakiimo-Signature";

export const TIMESTAMP_TOLERANCE_PAST_SEC = 300;
export const TIMESTAMP_TOLERANCE_FUTURE_SEC = 60;

/**
 * 署名対象の文字列を構築する。
 * 形式: `${version}\n${timestamp}\n${body}`
 */
export function buildSignedMessage(version: number, timestamp: number, body: string): string {
  return `${version}\n${timestamp}\n${body}`;
}

/**
 * HMAC-SHA256 で署名を計算し、hex (64 chars, lowercase) で返す。
 * Web Crypto API を使用 (Cloudflare Worker / Node.js 22+ / browser で動作)。
 */
export async function signEnvelope(secret: string, timestamp: number, body: string): Promise<string> {
  const message = buildSignedMessage(CONTRACT_VERSION, timestamp, body);
  return await computeHmacHex(secret, message);
}

export type EnvelopeVerifyResult =
  | { ok: true }
  | { ok: false; error: "version_unsupported" | "timestamp_out_of_range" | "signature_mismatch" };

export interface VerifyEnvelopeArgs {
  secret: string;
  version: number;
  timestamp: number;
  signature: string;
  body: string;
  /** Unix epoch 秒。テストで固定可能にするため必須。 */
  now: number;
}

export async function verifyEnvelope(args: VerifyEnvelopeArgs): Promise<EnvelopeVerifyResult> {
  if (args.version !== CONTRACT_VERSION) {
    return { ok: false, error: "version_unsupported" };
  }
  if (
    args.timestamp < args.now - TIMESTAMP_TOLERANCE_PAST_SEC ||
    args.timestamp > args.now + TIMESTAMP_TOLERANCE_FUTURE_SEC
  ) {
    return { ok: false, error: "timestamp_out_of_range" };
  }
  const expected = await computeHmacHex(args.secret, buildSignedMessage(args.version, args.timestamp, args.body));
  if (!constantTimeEquals(expected, args.signature.toLowerCase())) {
    return { ok: false, error: "signature_mismatch" };
  }
  return { ok: true };
}

async function computeHmacHex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

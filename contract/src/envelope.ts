// Yakiimo Ingest Contract — Envelope (HMAC 認証層)

export const CONTRACT_VERSION = 1;

/**
 * Worker が受信した signature を検証する際に試行する version の集合。
 * 非アトミック OTA migration 期間 (Worker 先行 deploy + ESP32 firmware が遅れる)
 * に備えて配列で持つ。新 version リリース時は [1, 2] 等で両受け、ESP32 全数
 * 移行後に [2] に絞る。
 */
export const SUPPORTED_VERSIONS = [1] as const;

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
 * 署名は CONTRACT_VERSION (現行) で生成。
 */
export async function signEnvelope(secret: string, timestamp: number, body: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const message = buildSignedMessage(CONTRACT_VERSION, timestamp, body);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export type EnvelopeVerifyResult =
  | { ok: true; version: number }
  | { ok: false; error: "timestamp_out_of_range" | "signature_mismatch" };

export interface VerifyEnvelopeArgs {
  secret: string;
  timestamp: number;
  signature: string;
  body: string;
  /** Unix epoch 秒。テストで固定可能にするため必須。 */
  now: number;
}

/**
 * 受信した signature を SUPPORTED_VERSIONS 各々で検証試行する。
 * いずれかで一致すれば accept (合致した version を返す)、全て一致しなければ reject。
 *
 * 注: signature_mismatch と version_unsupported を区別しない。攻撃側に
 * supported version 一覧を見せない防御効果を兼ねる。
 */
export async function verifyEnvelope(args: VerifyEnvelopeArgs): Promise<EnvelopeVerifyResult> {
  if (
    args.timestamp < args.now - TIMESTAMP_TOLERANCE_PAST_SEC ||
    args.timestamp > args.now + TIMESTAMP_TOLERANCE_FUTURE_SEC
  ) {
    return { ok: false, error: "timestamp_out_of_range" };
  }

  const sigBytes = hexToBytes(args.signature);
  if (!sigBytes) {
    return { ok: false, error: "signature_mismatch" };
  }

  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(args.secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );

  for (const v of SUPPORTED_VERSIONS) {
    const message = buildSignedMessage(v, args.timestamp, args.body);
    const ok = await crypto.subtle.verify("HMAC", key, sigBytes, enc.encode(message));
    if (ok) return { ok: true, version: v };
  }

  return { ok: false, error: "signature_mismatch" };
}

/** hex 文字列を Uint8Array に。不正 hex (奇数長 / 非 hex char) は null を返す。 */
function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    const byte = parseInt(hex.substr(i * 2, 2), 16);
    if (Number.isNaN(byte)) return null;
    bytes[i] = byte;
  }
  return bytes;
}

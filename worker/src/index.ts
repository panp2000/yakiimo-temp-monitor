interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  INGEST_HMAC_SECRET: string;
}

const TIMESTAMP_TOLERANCE_PAST_SEC = 300;   // 5 分
const TIMESTAMP_TOLERANCE_FUTURE_SEC = 60;  // 1 分

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // メソッド + パス確認
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/ingest") {
      return new Response("Not Found", { status: 404 });
    }

    // Content-Type 確認
    const ct = request.headers.get("content-type") || "";
    if (!ct.includes("application/json")) {
      return new Response("Unsupported Media Type", { status: 415 });
    }

    // 必須ヘッダ
    const tsHeader = request.headers.get("x-yakiimo-timestamp");
    const sigHeader = request.headers.get("x-yakiimo-signature");
    if (!tsHeader || !sigHeader) {
      return new Response("Missing auth headers", { status: 401 });
    }

    // timestamp 検証
    const ts = parseInt(tsHeader, 10);
    if (!Number.isFinite(ts)) {
      return new Response("Invalid timestamp", { status: 401 });
    }
    const now = Math.floor(Date.now() / 1000);
    if (ts < now - TIMESTAMP_TOLERANCE_PAST_SEC || ts > now + TIMESTAMP_TOLERANCE_FUTURE_SEC) {
      console.warn(`timestamp out of range: ts=${ts} now=${now}`);
      return new Response("Timestamp out of range", { status: 401 });
    }

    // body 取得
    const body = await request.text();
    if (!body) {
      return new Response("Empty body", { status: 400 });
    }

    // HMAC 検証
    const expected = await computeHmacHex(env.INGEST_HMAC_SECRET, `${ts}\n${body}`);
    if (!constantTimeEquals(expected, sigHeader.toLowerCase())) {
      console.warn("HMAC mismatch");
      return new Response("Invalid signature", { status: 401 });
    }

    // Supabase へ転送
    const upstream = await fetch(`${env.SUPABASE_URL}/rest/v1/yakiimo_temp_logs`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": env.SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        "Prefer": "return=minimal",
      },
      body,
    });

    if (!upstream.ok) {
      const detail = await upstream.text().catch(() => "");
      console.error(`Supabase upstream error status=${upstream.status} body=${detail.slice(0, 500)}`);
      return new Response(`Upstream error: ${upstream.status}`, { status: 502 });
    }

    console.log(`ingest OK status=${upstream.status} body_len=${body.length}`);
    return new Response(null, { status: upstream.status });
  },
};

async function computeHmacHex(secret: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
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

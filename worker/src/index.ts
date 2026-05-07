import {
  TIMESTAMP_HEADER,
  SIGNATURE_HEADER,
  verifyEnvelope,
} from "@yakiimo/contract/envelope";
import { validateLogRow } from "@yakiimo/contract/payload";

interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  INGEST_HMAC_SECRET: string;
}

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

    // 必須ヘッダ (HTTP ヘッダは大小無視。Worker runtime は小文字で来る)
    const tsHeader = request.headers.get(TIMESTAMP_HEADER.toLowerCase());
    const sigHeader = request.headers.get(SIGNATURE_HEADER.toLowerCase());
    if (!tsHeader || !sigHeader) {
      return new Response("Missing auth headers", { status: 401 });
    }

    const ts = parseInt(tsHeader, 10);
    if (!Number.isFinite(ts)) {
      return new Response("Invalid timestamp", { status: 401 });
    }

    // body 取得
    const body = await request.text();
    if (!body) {
      return new Response("Empty body", { status: 400 });
    }

    // Layer 1: Envelope 検証 (HMAC + timestamp tolerance + version)
    const envelopeResult = await verifyEnvelope({
      secret: env.INGEST_HMAC_SECRET,
      timestamp: ts,
      signature: sigHeader,
      body,
      now: Math.floor(Date.now() / 1000),
    });
    if (!envelopeResult.ok) {
      console.warn(`envelope rejected: ${envelopeResult.error} ts=${ts}`);
      switch (envelopeResult.error) {
        case "timestamp_out_of_range":
          return new Response("Timestamp out of range", { status: 401 });
        case "signature_mismatch":
          return new Response("Invalid signature", { status: 401 });
      }
    }
    // type narrow: 上の if/switch 全 error case が return 抜けるため
    // ここでは envelopeResult.ok === true が確定し version にアクセス可能
    const acceptedVersion = envelopeResult.version;

    // Layer 2: Payload 検証 (LogRow array)
    let parsed: unknown;
    try {
      parsed = JSON.parse(body);
    } catch (_e) {
      return new Response("Invalid JSON", { status: 400 });
    }
    if (!Array.isArray(parsed)) {
      return new Response("Body must be an array of LogRow", { status: 400 });
    }
    const validationErrors: { index: number; errors: unknown[] }[] = [];
    for (let i = 0; i < parsed.length; i++) {
      const result = validateLogRow(parsed[i]);
      if (!result.ok) {
        validationErrors.push({ index: i, errors: result.errors });
      }
    }
    if (validationErrors.length > 0) {
      console.warn(`payload validation failed: ${JSON.stringify(validationErrors).slice(0, 500)}`);
      return new Response(
        JSON.stringify({ error: "payload_invalid", details: validationErrors }),
        { status: 422, headers: { "Content-Type": "application/json" } },
      );
    }

    // Supabase へ転送
    const upstream = await fetch(`${env.SUPABASE_URL}/rest/v1/yakiimo_temp_logs`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": env.SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        "Prefer": "return=minimal, resolution=ignore-duplicates",
      },
      body,
    });

    if (!upstream.ok) {
      const detail = await upstream.text().catch(() => "");
      console.error(`supabase upstream error status=${upstream.status} body=${detail.slice(0, 500)}`);
      return new Response(`Upstream error: ${upstream.status}`, { status: 502 });
    }

    console.log(`ingest OK version=${acceptedVersion} rows=${parsed.length} body_len=${body.length}`);
    return new Response(null, { status: upstream.status });
  },
};

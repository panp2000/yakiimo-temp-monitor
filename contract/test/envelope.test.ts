import { describe, it, expect } from "vitest";
import {
  CONTRACT_VERSION,
  SUPPORTED_VERSIONS,
  buildSignedMessage,
  signEnvelope,
  verifyEnvelope,
} from "../src/envelope.js";

describe("buildSignedMessage", () => {
  it("constructs `${version}\\n${timestamp}\\n${body}` format", () => {
    expect(buildSignedMessage(1, 1700000000, "hello")).toBe("1\n1700000000\nhello");
  });
});

describe("signEnvelope / verifyEnvelope round-trip", () => {
  const SECRET = "test-secret-1234567890";
  const NOW = 1700000000;

  it("accepts valid signature within tolerance and returns version", async () => {
    const sig = await signEnvelope(SECRET, NOW, "body-x");
    const result = await verifyEnvelope({
      secret: SECRET,
      timestamp: NOW,
      signature: sig,
      body: "body-x",
      now: NOW,
    });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.version).toBe(CONTRACT_VERSION);
  });

  it("rejects timestamp older than 300s past tolerance", async () => {
    const sig = await signEnvelope(SECRET, NOW, "body-x");
    const result = await verifyEnvelope({
      secret: SECRET,
      timestamp: NOW,
      signature: sig,
      body: "body-x",
      now: NOW + 301,
    });
    expect(result).toEqual({ ok: false, error: "timestamp_out_of_range" });
  });

  it("rejects timestamp newer than 60s future tolerance", async () => {
    const sig = await signEnvelope(SECRET, NOW + 100, "body-x");
    const result = await verifyEnvelope({
      secret: SECRET,
      timestamp: NOW + 100,
      signature: sig,
      body: "body-x",
      now: NOW,
    });
    expect(result).toEqual({ ok: false, error: "timestamp_out_of_range" });
  });

  it("rejects signature mismatch (wrong secret)", async () => {
    const sig = await signEnvelope("other-secret", NOW, "body-x");
    const result = await verifyEnvelope({
      secret: SECRET,
      timestamp: NOW,
      signature: sig,
      body: "body-x",
      now: NOW,
    });
    expect(result).toEqual({ ok: false, error: "signature_mismatch" });
  });

  it("rejects signature mismatch (tampered body)", async () => {
    const sig = await signEnvelope(SECRET, NOW, "body-original");
    const result = await verifyEnvelope({
      secret: SECRET,
      timestamp: NOW,
      signature: sig,
      body: "body-tampered",
      now: NOW,
    });
    expect(result).toEqual({ ok: false, error: "signature_mismatch" });
  });

  it("rejects malformed hex signature", async () => {
    const result = await verifyEnvelope({
      secret: SECRET,
      timestamp: NOW,
      signature: "not-a-hex-string!@#$",
      body: "body-x",
      now: NOW,
    });
    expect(result).toEqual({ ok: false, error: "signature_mismatch" });
  });

  it("rejects odd-length hex signature", async () => {
    const result = await verifyEnvelope({
      secret: SECRET,
      timestamp: NOW,
      signature: "abc",  // odd length
      body: "body-x",
      now: NOW,
    });
    expect(result).toEqual({ ok: false, error: "signature_mismatch" });
  });
});

describe("SUPPORTED_VERSIONS", () => {
  it("contains current CONTRACT_VERSION", () => {
    expect((SUPPORTED_VERSIONS as readonly number[]).includes(CONTRACT_VERSION)).toBe(true);
  });
});

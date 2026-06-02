import crypto from "node:crypto";
import { describe, expect, test } from "bun:test";
import {
  apnsHostForEnvironment,
  buildApnsPayload,
  shouldPruneToken,
} from "../services/apns/payload";
import { summarizeApnsSendResults } from "../services/apns/response";
import { signApnsJwt, normalizeP8 } from "../services/apns/sender";
import {
  MAX_PUSH_BODY_CHARS,
  normalizeApnsBundle,
  parsePushPayload,
  readBoundedJsonObject,
} from "../services/apns/routePolicy";

describe("apns payload", () => {
  test("builds a time-sensitive alert with deep-link keys", () => {
    const payload = buildApnsPayload({
      title: "claude",
      subtitle: "issue-118",
      body: "Agent finished",
      workspaceId: "ws-1",
      surfaceId: "sf-2",
    }) as { aps: Record<string, unknown>; cmux: Record<string, string> };

    expect(payload.aps.alert).toEqual({ title: "claude", subtitle: "issue-118", body: "Agent finished" });
    expect(payload.aps["interruption-level"]).toBe("time-sensitive");
    expect(payload.aps.sound).toBe("default");
    expect(payload.cmux).toEqual({ workspaceId: "ws-1", surfaceId: "sf-2" });
  });

  test("omits cmux block when no ids", () => {
    const payload = buildApnsPayload({ title: "t", body: "b" }) as Record<string, unknown>;
    expect("cmux" in payload).toBe(false);
  });

  test("hideContent redacts title/subtitle/body but keeps deep-link", () => {
    const payload = buildApnsPayload({
      title: "secret-host",
      subtitle: "secret",
      body: "rm -rf secret output",
      workspaceId: "ws-9",
      hideContent: true,
    }) as { aps: { alert: Record<string, string> }; cmux: Record<string, string> };

    expect(payload.aps.alert.title).toBe("cmux");
    expect(payload.aps.alert.body).toBe("An agent needs your attention");
    expect(payload.aps.alert.subtitle).toBeUndefined();
    expect(payload.cmux).toEqual({ workspaceId: "ws-9" });
  });

  test("empty title falls back to cmux", () => {
    const payload = buildApnsPayload({ title: "   ", body: "b" }) as { aps: { alert: { title: string } } };
    expect(payload.aps.alert.title).toBe("cmux");
  });
});

describe("apns host + pruning", () => {
  test("host selection", () => {
    expect(apnsHostForEnvironment("sandbox")).toBe("api.sandbox.push.apple.com");
    expect(apnsHostForEnvironment("production")).toBe("api.push.apple.com");
    expect(apnsHostForEnvironment("unknown")).toBe("api.push.apple.com");
  });

  test("prunes only terminal failures", () => {
    expect(shouldPruneToken(410, undefined)).toBe(true);
    expect(shouldPruneToken(400, "BadDeviceToken")).toBe(true);
    expect(shouldPruneToken(400, "DeviceTokenNotForTopic")).toBe(true);
    expect(shouldPruneToken(200, undefined)).toBe(false);
    expect(shouldPruneToken(0, "timeout")).toBe(false); // transient
    expect(shouldPruneToken(503, "ServiceUnavailable")).toBe(false); // transient
    expect(shouldPruneToken(429, "TooManyRequests")).toBe(false);
  });
});

describe("apns response", () => {
  test("uses a stable summary shape when there are no devices", () => {
    expect(summarizeApnsSendResults([])).toEqual({ sent: 0, devices: 0, pruned: 0 });
  });

  test("summarizes sends without exposing provider reasons", () => {
    const summary = summarizeApnsSendResults([
      { deviceToken: "a".repeat(64), status: 200, prune: false },
      { deviceToken: "b".repeat(64), status: 400, reason: "BadDeviceToken", prune: true },
    ]);

    expect(summary).toEqual({ sent: 1, devices: 2, pruned: 1 });
    expect(JSON.stringify(summary)).not.toContain("BadDeviceToken");
    expect(JSON.stringify(summary)).not.toContain("apns");
  });
});

describe("apns route policy", () => {
  test("allows only cmux iOS bundle IDs and derives the APNs environment", () => {
    expect(normalizeApnsBundle("com.cmuxterm.app")).toEqual({
      bundleId: "com.cmuxterm.app",
      environment: "production",
    });
    expect(normalizeApnsBundle("dev.cmux.app.beta")).toEqual({
      bundleId: "dev.cmux.app.beta",
      environment: "production",
    });
    expect(normalizeApnsBundle("dev.cmux.ios.push1")).toEqual({
      bundleId: "dev.cmux.ios.push1",
      environment: "sandbox",
    });

    expect(normalizeApnsBundle("com.example.app")).toBeNull();
    expect(normalizeApnsBundle("dev.cmux.ios.bad_topic")).toBeNull();
    expect(normalizeApnsBundle("dev.cmux.ios.-bad")).toBeNull();
  });

  test("bounds and trims push payloads before sending to APNs", () => {
    const parsed = parsePushPayload({
      title: " agent ",
      subtitle: " workspace ",
      body: " done ",
      workspaceId: " ws-1 ",
      surfaceId: " sf-1 ",
      hideContent: true,
    });

    expect(parsed).toEqual({
      ok: true,
      value: {
        title: "agent",
        subtitle: "workspace",
        body: "done",
        workspaceId: "ws-1",
        surfaceId: "sf-1",
        hideContent: true,
      },
    });

    expect(parsePushPayload({ title: "", body: "" })).toEqual({
      ok: false,
      error: "empty_notification",
    });
    expect(parsePushPayload({ title: "agent", body: "x".repeat(MAX_PUSH_BODY_CHARS + 1) })).toEqual({
      ok: false,
      error: "body_too_long",
    });
  });

  test("reads only bounded JSON objects from requests", async () => {
    await expect(
      readBoundedJsonObject(
        new Request("https://example.test", {
          method: "POST",
          headers: { "content-length": "9000" },
          body: "{}",
        }),
        8,
      ),
    ).resolves.toEqual({ ok: false, error: "request_too_large" });

    await expect(
      readBoundedJsonObject(
        new Request("https://example.test", {
          method: "POST",
          body: JSON.stringify({ body: "123456789" }),
        }),
        8,
      ),
    ).resolves.toEqual({ ok: false, error: "request_too_large" });

    await expect(
      readBoundedJsonObject(
        new Request("https://example.test", {
          method: "POST",
          body: JSON.stringify(["not", "object"]),
        }),
        64,
      ),
    ).resolves.toEqual({ ok: false, error: "invalid_json" });

    await expect(
      readBoundedJsonObject(
        new Request("https://example.test", {
          method: "POST",
          body: JSON.stringify({ title: "agent" }),
        }),
        64,
      ),
    ).resolves.toEqual({ ok: true, value: { title: "agent" } });
  });
});

describe("apns jwt", () => {
  test("normalizeP8 expands literal newlines", () => {
    expect(normalizeP8("a\\nb\\nc")).toBe("a\nb\nc");
    expect(normalizeP8("a\nb")).toBe("a\nb");
  });

  test("signs a verifiable ES256 JWT with kid/iss/iat", () => {
    const { privateKey, publicKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    const now = 1_700_000_000;
    const jwt = signApnsJwt({ keyP8: p8, keyId: "KID123", teamId: "TEAM456" }, now);

    const [headerB64, claimsB64, sigB64] = jwt.split(".");
    const decode = (s: string) =>
      JSON.parse(Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8"));
    expect(decode(headerB64)).toEqual({ alg: "ES256", kid: "KID123" });
    expect(decode(claimsB64)).toEqual({ iss: "TEAM456", iat: now });

    const signature = Buffer.from(sigB64.replace(/-/g, "+").replace(/_/g, "/"), "base64");
    const valid = crypto.verify(
      "sha256",
      Buffer.from(`${headerB64}.${claimsB64}`),
      { key: publicKey, dsaEncoding: "ieee-p1363" },
      signature,
    );
    expect(valid).toBe(true);
  });
});

import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import type http2 from "node:http2";
import { describe, expect, test } from "bun:test";
import {
  apnsHostForEnvironment,
  buildApnsPayload,
  CMUX_APNS_CATEGORY,
  shouldPruneToken,
} from "../services/apns/payload";
import { summarizeApnsSendResults } from "../services/apns/response";
import { sendApnsNotification, signApnsJwt, normalizeP8 } from "../services/apns/sender";
import {
  MAX_PUSH_BADGE_COUNT,
  MAX_PUSH_BODY_CHARS,
  MAX_PUSH_DISMISS_IDS,
  MAX_PUSH_ID_CHARS,
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
      macDeviceId: "mac-3",
    }) as { aps: Record<string, unknown>; cmux: Record<string, string> };

    expect(payload.aps.alert).toEqual({ title: "claude", subtitle: "issue-118", body: "Agent finished" });
    expect(payload.aps["interruption-level"]).toBe("time-sensitive");
    expect(payload.aps.sound).toBe("default");
    expect(payload.cmux).toEqual({ workspaceId: "ws-1", surfaceId: "sf-2", macDeviceId: "mac-3" });
  });

  test("omits cmux block when no ids", () => {
    const payload = buildApnsPayload({ title: "t", body: "b" }) as Record<string, unknown>;
    expect("cmux" in payload).toBe(false);
  });

  test("carries the stable notification id and dismiss-sync category", () => {
    const payload = buildApnsPayload({
      title: "claude",
      body: "Agent finished",
      workspaceId: "ws-1",
      notificationId: "n-42",
    }) as { aps: Record<string, unknown>; cmux: Record<string, string> };

    // The category is what arms iOS customDismissAction; the cmux key lets an
    // iOS swipe tell the Mac which notification was dismissed.
    expect(payload.aps.category).toBe(CMUX_APNS_CATEGORY);
    expect(payload.cmux).toEqual({ workspaceId: "ws-1", notificationId: "n-42" });
  });

  test("keeps the notification id even when content is hidden (id is not content)", () => {
    const payload = buildApnsPayload({
      title: "secret",
      body: "secret output",
      notificationId: "n-9",
      hideContent: true,
    }) as { aps: { alert: Record<string, string>; category: string }; cmux: Record<string, string> };

    expect(payload.aps.alert.title).toBe("cmux");
    expect(payload.aps.category).toBe(CMUX_APNS_CATEGORY);
    expect(payload.cmux).toEqual({ notificationId: "n-9" });
  });

  test("hideContent redacts terminal content but keeps a generic compatibility body and deep-link", () => {
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

  test("stamps aps.badge with the authoritative unread count on a notify push", () => {
    const payload = buildApnsPayload({
      title: "claude",
      body: "Agent finished",
      badgeCount: 3,
    }) as { aps: Record<string, unknown> };

    expect(payload.aps.badge).toBe(3);
  });

  test("leaves the badge alone when no count was sent (older Macs)", () => {
    const payload = buildApnsPayload({ title: "t", body: "b" }) as { aps: Record<string, unknown> };
    expect("badge" in payload.aps).toBe(false);
  });

  test("dismiss push is banner-less: content-available + badge + dismissed ids only", () => {
    const payload = buildApnsPayload({
      kind: "dismiss",
      title: "",
      body: "",
      dismissedIds: ["n-1", "n-2"],
      badgeCount: 0,
    }) as { aps: Record<string, unknown>; cmux: Record<string, unknown> };

    expect(payload.aps).toEqual({ "content-available": 1, badge: 0 });
    // Nothing visible: no alert, no sound, no category.
    expect("alert" in payload.aps).toBe(false);
    expect("sound" in payload.aps).toBe(false);
    expect(payload.cmux).toEqual({ dismissedIds: ["n-1", "n-2"] });
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
      macDeviceId: " mac-1 ",
      notificationId: " n-1 ",
      hideContent: true,
    });

    expect(parsed).toEqual({
      ok: true,
      value: {
        kind: "notify",
        title: "agent",
        subtitle: "workspace",
        body: "done",
        workspaceId: "ws-1",
        surfaceId: "sf-1",
        macDeviceId: "mac-1",
        notificationId: "n-1",
        dismissedIds: [],
        badgeCount: null,
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

  test("absent notificationId parses to null and over-long is rejected", () => {
    const parsed = parsePushPayload({ title: "agent", body: "done" });
    expect(parsed).toEqual({
      ok: true,
      value: {
        kind: "notify",
        title: "agent",
        subtitle: null,
        body: "done",
        workspaceId: null,
        surfaceId: null,
        macDeviceId: null,
        notificationId: null,
        dismissedIds: [],
        badgeCount: null,
        hideContent: false,
      },
    });

    expect(
      parsePushPayload({ title: "agent", body: "done", notificationId: "x".repeat(MAX_PUSH_ID_CHARS + 1) }),
    ).toEqual({ ok: false, error: "notification_id_too_long" });
  });

  test("parses a dismiss push: text-free, requires ids, carries the badge", () => {
    const parsed = parsePushPayload({
      kind: "dismiss",
      notificationIds: [" n-1 ", "n-2"],
      badgeCount: 4,
    });

    expect(parsed).toEqual({
      ok: true,
      value: {
        kind: "dismiss",
        title: "",
        subtitle: null,
        body: "",
        workspaceId: null,
        surfaceId: null,
        macDeviceId: null,
        notificationId: null,
        dismissedIds: ["n-1", "n-2"],
        badgeCount: 4,
        hideContent: false,
      },
    });

    expect(parsePushPayload({ kind: "dismiss", badgeCount: 0 })).toEqual({
      ok: false,
      error: "missing_dismissed_ids",
    });
    expect(parsePushPayload({ kind: "dismiss", notificationIds: "n-1" })).toEqual({
      ok: false,
      error: "bad_notification_ids",
    });
    expect(
      parsePushPayload({
        kind: "dismiss",
        notificationIds: Array.from({ length: MAX_PUSH_DISMISS_IDS + 1 }, (_, i) => `n-${i}`),
      }),
    ).toEqual({ ok: false, error: "too_many_notification_ids" });
    expect(
      parsePushPayload({ kind: "dismiss", notificationIds: ["x".repeat(MAX_PUSH_ID_CHARS + 1)] }),
    ).toEqual({ ok: false, error: "notification_id_too_long" });
  });

  test("badge count is tolerant: malformed is ignored, runaway is clamped", () => {
    const value = (badgeCount: unknown) => {
      const parsed = parsePushPayload({ title: "agent", body: "done", badgeCount });
      if (!parsed.ok) throw new Error(parsed.error);
      return parsed.value.badgeCount;
    };

    expect(value(7)).toBe(7);
    expect(value(0)).toBe(0);
    expect(value(undefined)).toBeNull();
    expect(value("7")).toBeNull();
    expect(value(-1)).toBeNull();
    expect(value(1.5)).toBeNull();
    expect(value(MAX_PUSH_BADGE_COUNT + 100)).toBe(MAX_PUSH_BADGE_COUNT);
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

describe("apns sender transport", () => {
  test("starts sandbox and production host groups concurrently", async () => {
    const sandboxHost = apnsHostForEnvironment("sandbox");
    const productionHost = apnsHostForEnvironment("production");
    const started: string[] = [];
    const closed: string[] = [];
    let releaseSandbox!: () => void;
    const sandboxReleased = new Promise<void>((resolve) => {
      releaseSandbox = resolve;
    });

    class FakeRequest extends EventEmitter {
      constructor(private readonly host: string) {
        super();
      }

      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        started.push(this.host);
        this.emit("response", { ":status": 200 });
        if (this.host === sandboxHost) {
          void sandboxReleased.then(() => this.emit("end"));
        } else {
          this.emit("end");
        }
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      constructor(private readonly host: string) {
        super();
      }

      request() {
        return new FakeRequest(this.host);
      }

      close() {
        closed.push(this.host);
      }
    }

    const transport = {
      connect: (host: string) => new FakeSession(host),
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    const resultPromise = sendApnsNotification(
      { keyP8: p8, keyId: "KID-CONCURRENT", teamId: "TEAM456" },
      [
        { deviceToken: "a".repeat(64), bundleId: "dev.cmux.ios.push1", environment: "sandbox" },
        { deviceToken: "b".repeat(64), bundleId: "com.cmuxterm.app", environment: "production" },
      ],
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    let results: Awaited<ReturnType<typeof sendApnsNotification>> = [];
    try {
      // Fake req.end() is synchronous here, so both host groups have started before any await.
      expect(started).toEqual([sandboxHost, productionHost]);
    } finally {
      releaseSandbox();
      results = await resultPromise;
    }

    expect(results).toEqual([
      { deviceToken: "a".repeat(64), status: 200, reason: undefined, prune: false },
      { deviceToken: "b".repeat(64), status: 200, reason: undefined, prune: false },
    ]);
    expect(closed).toEqual([productionHost, sandboxHost]);
  });

  test("keeps healthy host results when another host cannot connect", async () => {
    const sandboxHost = apnsHostForEnvironment("sandbox");
    const productionHost = apnsHostForEnvironment("production");
    const closed: string[] = [];

    class FakeRequest extends EventEmitter {
      constructor(private readonly host: string) {
        super();
      }

      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      constructor(private readonly host: string) {
        super();
      }

      request() {
        return new FakeRequest(this.host);
      }

      close() {
        closed.push(this.host);
      }
    }

    const transport = {
      connect: (host: string) => {
        if (host === sandboxHost) {
          throw new Error("connect failed");
        }
        return new FakeSession(host);
      },
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    const results = await sendApnsNotification(
      { keyP8: p8, keyId: "KID-PARTIAL", teamId: "TEAM456" },
      [
        { deviceToken: "a".repeat(64), bundleId: "dev.cmux.ios.push1", environment: "sandbox" },
        { deviceToken: "b".repeat(64), bundleId: "com.cmuxterm.app", environment: "production" },
      ],
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    expect(results).toEqual([
      { deviceToken: "a".repeat(64), status: 0, reason: "connection_error", prune: false },
      { deviceToken: "b".repeat(64), status: 200, reason: undefined, prune: false },
    ]);
    expect(closed).toEqual([productionHost]);
  });

  test("keeps same-host successes when another request fails to start", async () => {
    const productionHost = apnsHostForEnvironment("production");
    const closed: string[] = [];

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      private requestCount = 0;

      request() {
        this.requestCount += 1;
        if (this.requestCount === 2) {
          throw new Error("request failed");
        }
        return new FakeRequest();
      }

      close() {
        closed.push(productionHost);
      }
    }

    const transport = {
      connect: (host: string) => {
        expect(host).toBe(productionHost);
        return new FakeSession();
      },
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    const results = await sendApnsNotification(
      { keyP8: p8, keyId: "KID-SAME-HOST-PARTIAL", teamId: "TEAM456" },
      [
        { deviceToken: "a".repeat(64), bundleId: "com.cmuxterm.app", environment: "production" },
        { deviceToken: "b".repeat(64), bundleId: "dev.cmux.app.beta", environment: "production" },
      ],
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    expect(results).toEqual([
      { deviceToken: "a".repeat(64), status: 200, reason: undefined, prune: false },
      { deviceToken: "b".repeat(64), status: 0, reason: "request failed", prune: false },
    ]);
    expect(closed).toEqual([productionHost]);
  });

  test("stamps apns-collapse-id from the notification id so the banner is dismiss-syncable", async () => {
    const capturedHeaders: http2.OutgoingHttpHeaders[] = [];

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }
      close() {
        return this;
      }
      end() {
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      request(headers: http2.OutgoingHttpHeaders) {
        capturedHeaders.push(headers);
        return new FakeRequest();
      }
      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    await sendApnsNotification(
      { keyP8: p8, keyId: "KID-COLLAPSE", teamId: "TEAM456" },
      [{ deviceToken: "a".repeat(64), bundleId: "com.cmuxterm.app", environment: "production" }],
      { title: "agent", body: "done", notificationId: "n-7" },
      1000,
      transport,
    );

    expect(capturedHeaders).toHaveLength(1);
    expect(capturedHeaders[0]["apns-collapse-id"]).toBe("n-7");
  });

  test("omits apns-collapse-id when there is no notification id", async () => {
    const capturedHeaders: http2.OutgoingHttpHeaders[] = [];

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }
      close() {
        return this;
      }
      end() {
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      request(headers: http2.OutgoingHttpHeaders) {
        capturedHeaders.push(headers);
        return new FakeRequest();
      }
      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    await sendApnsNotification(
      { keyP8: p8, keyId: "KID-NO-COLLAPSE", teamId: "TEAM456" },
      [{ deviceToken: "a".repeat(64), bundleId: "com.cmuxterm.app", environment: "production" }],
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    expect(capturedHeaders).toHaveLength(1);
    expect("apns-collapse-id" in capturedHeaders[0]).toBe(false);
  });

  test("dismiss push: never collapses onto the banner and downgrades to priority 5", async () => {
    const capturedHeaders: http2.OutgoingHttpHeaders[] = [];

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }
      close() {
        return this;
      }
      end() {
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      request(headers: http2.OutgoingHttpHeaders) {
        capturedHeaders.push(headers);
        return new FakeRequest();
      }
      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    await sendApnsNotification(
      { keyP8: p8, keyId: "KID-DISMISS", teamId: "TEAM456" },
      [{ deviceToken: "a".repeat(64), bundleId: "com.cmuxterm.app", environment: "production" }],
      {
        kind: "dismiss",
        title: "",
        body: "",
        // notificationId would normally collapse; a dismiss push must NOT,
        // or APNs would replace the visible banner with the silent payload.
        notificationId: "n-7",
        dismissedIds: ["n-7"],
        badgeCount: 0,
      },
      1000,
      transport,
    );

    expect(capturedHeaders).toHaveLength(1);
    expect("apns-collapse-id" in capturedHeaders[0]).toBe(false);
    expect(capturedHeaders[0]["apns-priority"]).toBe("5");
  });

  test("notify push keeps the default immediate priority", async () => {
    const capturedHeaders: http2.OutgoingHttpHeaders[] = [];

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }
      close() {
        return this;
      }
      end() {
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      request(headers: http2.OutgoingHttpHeaders) {
        capturedHeaders.push(headers);
        return new FakeRequest();
      }
      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    await sendApnsNotification(
      { keyP8: p8, keyId: "KID-NOTIFY-PRIO", teamId: "TEAM456" },
      [{ deviceToken: "a".repeat(64), bundleId: "com.cmuxterm.app", environment: "production" }],
      { title: "agent", body: "done", badgeCount: 2 },
      1000,
      transport,
    );

    expect(capturedHeaders).toHaveLength(1);
    expect("apns-priority" in capturedHeaders[0]).toBe(false);
  });
});

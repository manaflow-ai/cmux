import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import type http2 from "node:http2";
import { describe, expect, test } from "bun:test";
import {
  apnsHostForEnvironment,
  buildApnsPayload,
  CMUX_APNS_CATEGORY,
  CMUX_APNS_REPLY_CATEGORY,
  shouldPruneToken,
} from "../services/apns/payload";
import { resolveApnsProviderConfiguration } from "../services/apns/config";
import { summarizeApnsSendResults } from "../services/apns/response";
import {
  clampRetryToEventLife,
  mergePushDeliveryOutcomes,
  unresolvedPushTargets,
} from "../services/apns/deliveryState";
import {
  APNS_DEFAULT_MAX_DELIVERY_DURATION_MS,
  APNS_MAX_PAYLOAD_BYTES,
  APNS_RATE_LIMIT_FALLBACK_SECONDS,
  APNS_SERVER_ERROR_RETRY_SECONDS,
  createApnsSessionPool,
  sendApnsNotification,
  sendApnsNotificationReliably,
  signApnsJwt,
  normalizeP8,
} from "../services/apns/sender";
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
      retargetsToLiveSurfaceOwner: false,
      macDeviceId: "mac-3",
    }) as { aps: Record<string, unknown>; cmux: Record<string, string | boolean> };

    expect(payload.aps.alert).toEqual({ title: "claude", subtitle: "issue-118", body: "Agent finished" });
    expect(payload.aps["interruption-level"]).toBe("time-sensitive");
    expect(payload.aps.sound).toBe("default");
    expect(payload.cmux).toEqual({
      workspaceId: "ws-1",
      surfaceId: "sf-2",
      retargetsToLiveSurfaceOwner: false,
      macDeviceId: "mac-3",
    });
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

  test("selects reply and fallback categories from replyShape", () => {
    const category = (replyShape: unknown) => {
      const payload = buildApnsPayload({
        title: "claude",
        body: "Agent finished",
        replyShape,
      } as Parameters<typeof buildApnsPayload>[0]) as { aps: Record<string, unknown> };
      return payload.aps.category;
    };

    expect(category("text")).toBe(CMUX_APNS_REPLY_CATEGORY);
    expect(category("none")).toBe(CMUX_APNS_CATEGORY);
    expect(category(undefined)).toBe(CMUX_APNS_CATEGORY);
    expect(category("unknown")).toBe(CMUX_APNS_CATEGORY);
  });

  test("keeps the notification id even when content is hidden (id is not content)", () => {
    const payload = buildApnsPayload({
      title: "secret",
      body: "secret output",
      notificationId: "n-9",
      hideContent: true,
    }) as { aps: { alert: Record<string, string>; category: string }; cmux: Record<string, string> };

    expect(payload.aps.alert).toEqual({
      "title-loc-key": "push.generic.title",
      "loc-key": "push.generic.body",
    });
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

    expect(payload.aps.alert["title-loc-key"]).toBe("push.generic.title");
    expect(payload.aps.alert["loc-key"]).toBe("push.generic.body");
    expect(payload.aps.alert.subtitle).toBeUndefined();
    expect(payload.cmux).toEqual({ workspaceId: "ws-9" });
  });

  test("preserves one opaque correlation id from Mac input through the provider body without content leakage", () => {
    const correlationId = "4d02de48-a21d-4ba1-97b5-42e9400ee09b";
    const parsed = parsePushPayload({
      title: "secret terminal title",
      subtitle: "secret subtitle",
      body: "secret terminal output",
      hideContent: true,
      correlationId,
    });
    if (!parsed.ok) throw new Error(parsed.error);

    const providerPayload = buildApnsPayload(parsed.value) as {
      aps: { alert: Record<string, string> };
      cmux: Record<string, string>;
    };
    expect(providerPayload.cmux.correlationId).toBe(correlationId);
    expect(providerPayload.aps.alert).toEqual({
      "title-loc-key": "push.generic.title",
      "loc-key": "push.generic.body",
    });
    expect(JSON.stringify(providerPayload)).not.toContain("secret");
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
    expect(apnsHostForEnvironment("unknown")).toBeNull();
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

describe("apns provider configuration", () => {
  test("requires all three nonblank provider credentials", () => {
    expect(resolveApnsProviderConfiguration("key", "key-id", "team-id")).toEqual({
      keyP8: "key",
      keyId: "key-id",
      teamId: "team-id",
    });
    expect(resolveApnsProviderConfiguration(undefined, "key-id", "team-id")).toBeNull();
    expect(resolveApnsProviderConfiguration("key", "   ", "team-id")).toBeNull();
    expect(resolveApnsProviderConfiguration("key", "key-id", "")).toBeNull();
  });
});

describe("apns response", () => {
  test("uses a stable summary shape when there are no devices", () => {
    expect(summarizeApnsSendResults([])).toEqual({
      sent: 0,
      devices: 0,
      pruned: 0,
      transientFailures: 0,
      permanentFailures: 0,
    });
  });

  test("classifies partial, transient, and permanent APNs outcomes without exposing provider reasons", () => {
    const summary = summarizeApnsSendResults([
      { deviceToken: "a".repeat(64), status: 200, prune: false },
      { deviceToken: "b".repeat(64), status: 400, reason: "BadDeviceToken", prune: true },
      { deviceToken: "c".repeat(64), status: 503, reason: "ServiceUnavailable", prune: false },
      { deviceToken: "d".repeat(64), status: 403, reason: "InvalidProviderToken", prune: false },
    ]);

    expect(summary).toEqual({
      sent: 1,
      devices: 4,
      pruned: 1,
      transientFailures: 1,
      permanentFailures: 2,
    });
    expect(JSON.stringify(summary)).not.toContain("BadDeviceToken");
    expect(JSON.stringify(summary)).not.toContain("ServiceUnavailable");
    expect(JSON.stringify(summary)).not.toContain("InvalidProviderToken");
    expect(JSON.stringify(summary)).not.toContain("apns");
  });
});

describe("apns logical-event delivery state", () => {
  test("a later same-correlation attempt targets only the transient device", () => {
    const targets = [
      {
        deviceToken: "a".repeat(64),
        bundleId: "com.cmux.app",
        environment: "production",
      },
      {
        deviceToken: "b".repeat(64),
        bundleId: "com.cmux.app",
        environment: "production",
      },
    ];
    const first = mergePushDeliveryOutcomes([], [
      {
        deviceToken: "a".repeat(64),
        status: 200,
        prune: false,
      },
      {
        deviceToken: "b".repeat(64),
        status: 503,
        reason: "ServiceUnavailable",
        prune: false,
      },
    ]);

    expect(unresolvedPushTargets(targets, first).map((target) => target.deviceToken))
      .toEqual(["b".repeat(64)]);
    const newlyRegistered = {
      deviceToken: "c".repeat(64),
      bundleId: "com.cmux.app",
      environment: "production",
    };
    expect(
      unresolvedPushTargets(
        [targets[1], newlyRegistered],
        first,
      ).map((target) => target.deviceToken),
    ).toEqual(["b".repeat(64), "c".repeat(64)]);
    // The route freezes/intersects the original target set before calling this
    // helper, so a newly registered C is excluded and an unregistered B stays
    // removed.
    const originalTargetTokens = new Set(targets.map((target) => target.deviceToken));
    const intersected = [targets[1], newlyRegistered].filter((target) =>
      originalTargetTokens.has(target.deviceToken)
    );
    expect(unresolvedPushTargets(intersected, first).map((target) => target.deviceToken))
      .toEqual(["b".repeat(64)]);
    expect(unresolvedPushTargets([], first)).toEqual([]);

    const recovered = mergePushDeliveryOutcomes(first, [
      {
        deviceToken: "b".repeat(64),
        status: 200,
        prune: false,
      },
    ]);
    expect(summarizeApnsSendResults(recovered).sent).toBe(2);
    expect(recovered.filter((result) => result.deviceToken.startsWith("a")))
      .toHaveLength(1);
  });

  test("a provider backoff longer than the event's life is clamped to a viable retry", () => {
    // 300s of event life left; the APNs 5xx policy asks for 900s. Unclamped,
    // the advertised retry lands 10 minutes after the event TTL and the alert
    // is silently lost. 28s is the bounded worst-case send duration margin.
    const clamped = clampRetryToEventLife(
      [
        {
          deviceToken: "a".repeat(64),
          status: 503,
          reason: "ServiceUnavailable",
          retryAfterSeconds: 900,
          prune: false,
        },
      ],
      new Date(1_000_750),
      1_300,
    );
    expect(clamped[0]?.retryAfterSeconds).toBe(270);
    expect(summarizeApnsSendResults(clamped).retryAfterSeconds).toBe(270);
  });

  test("a backoff the event outlives is untouched", () => {
    const clamped = clampRetryToEventLife(
      [
        {
          deviceToken: "a".repeat(64),
          status: 429,
          reason: "TooManyRequests",
          retryAfterSeconds: 60,
          prune: false,
        },
      ],
      new Date(1_000_000),
      1_300,
    );
    expect(clamped[0]?.retryAfterSeconds).toBe(60);
  });

  test("a short provider backoff is raised to the deferred retry floor", () => {
    const clamped = clampRetryToEventLife(
      [
        {
          deviceToken: "a".repeat(64),
          status: 429,
          reason: "TooManyRequests",
          retryAfterSeconds: 1,
          prune: false,
        },
      ],
      new Date(1_000_000),
      1_300,
    );
    expect(clamped[0]?.retryAfterSeconds).toBe(30);
  });

  test("a retry that cannot fit before the TTL finalizes as expired instead", () => {
    // Only 20s of life left: even the floor (30s) lands past the TTL, so
    // advertising any retry would be a lie. The target finalizes as expired
    // immediately and no backoff is published.
    const clamped = clampRetryToEventLife(
      [
        {
          targetId: "target-1",
          deviceToken: "a".repeat(64),
          status: 500,
          reason: "InternalServerError",
          retryAfterSeconds: 900,
          prune: false,
        },
      ],
      new Date(1_000_000),
      1_020,
    );
    expect(clamped[0]).toEqual({
      targetId: "target-1",
      deviceToken: "a".repeat(64),
      status: 0,
      reason: "event_expired",
      prune: false,
    });
    expect(
      summarizeApnsSendResults(clamped).retryAfterSeconds,
    ).toBeUndefined();
  });

  test("a transport failure without provider backoff gets the retry floor", () => {
    const clamped = clampRetryToEventLife(
      [
        {
          deviceToken: "a".repeat(64),
          status: 0,
          reason: "connection_error",
          prune: false,
        },
      ],
      new Date(1_000_000),
      1_300,
    );
    expect(clamped[0]?.retryAfterSeconds).toBe(30);
  });

  test("the retry floor is rejected one millisecond beyond the viable boundary", () => {
    const outcome = {
      targetId: "target-1",
      deviceToken: "a".repeat(64),
      status: 429,
      reason: "TooManyRequests",
      retryAfterSeconds: 0,
      prune: false,
    };
    expect(
      clampRetryToEventLife([outcome], new Date(1_000_999), 1_060)[0]
        ?.retryAfterSeconds,
    ).toBe(30);
    expect(
      clampRetryToEventLife([outcome], new Date(1_001_001), 1_060)[0],
    ).toMatchObject({ reason: "event_expired", status: 0 });
  });

  test("resolved and no-backoff outcomes pass through the clamp unchanged", () => {
    const outcomes = [
      {
        deviceToken: "a".repeat(64),
        status: 200,
        prune: false,
      },
      {
        deviceToken: "b".repeat(64),
        status: 0,
        reason: "event_expired",
        prune: false,
      },
    ];
    expect(
      clampRetryToEventLife(outcomes, new Date(1_000_000), 1_300),
    ).toEqual(outcomes);
  });
});

describe("apns route policy", () => {
  test("allows only cmux iOS bundle IDs and derives the APNs environment", () => {
    expect(normalizeApnsBundle("com.cmux.app")).toEqual({
      bundleId: "com.cmux.app",
      environment: "production",
    });
    expect(normalizeApnsBundle("com.cmuxterm.app")).toEqual({
      bundleId: "com.cmuxterm.app",
      environment: "production",
    });
    expect(normalizeApnsBundle("dev.cmux.app.beta")).toEqual({
      bundleId: "dev.cmux.app.beta",
      environment: "production",
    });
    expect(normalizeApnsBundle("com.cmux.app")).toEqual({
      bundleId: "com.cmux.app",
      environment: "production",
    });
    expect(normalizeApnsBundle("dev.cmux.ios.push1")).toEqual({
      bundleId: "dev.cmux.ios.push1",
      environment: "sandbox",
    });
    const maximumDevTag = "a".repeat(64);
    expect(normalizeApnsBundle(`dev.cmux.ios.${maximumDevTag}`)).toEqual({
      bundleId: `dev.cmux.ios.${maximumDevTag}`,
      environment: "sandbox",
    });
    expect(normalizeApnsBundle(`dev.cmux.ios.${maximumDevTag}a`)).toBeNull();

    expect(normalizeApnsBundle("com.example.app")).toBeNull();
    expect(normalizeApnsBundle("dev.cmux.ios.bad_topic")).toBeNull();
    expect(normalizeApnsBundle("dev.cmux.ios.-bad")).toBeNull();
  });

  test("allows the internal TestFlight bundle id as a production APNs topic", () => {
    // The scheduled internal TestFlight lane ships dev.cmux.app.internal
    // (.github/workflows/ios-testflight.yml); TestFlight uses the production
    // APNs environment. Rejecting it here makes every internal-beta phone fail
    // device-token registration with invalid_bundle_id, so pushes never arrive.
    expect(normalizeApnsBundle("dev.cmux.app.internal")).toEqual({
      bundleId: "dev.cmux.app.internal",
      environment: "production",
    });
  });

  test("allows the demo TestFlight bundle id as a production APNs topic", () => {
    // The manual demo lane variant ships dev.cmux.app.demo
    // (.github/workflows/ios-testflight.yml, variant=demo); TestFlight uses the
    // production APNs environment, same as the internal lane above.
    expect(normalizeApnsBundle("dev.cmux.app.demo")).toEqual({
      bundleId: "dev.cmux.app.demo",
      environment: "production",
    });
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
      retargetsToLiveSurfaceOwner: false,
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
        correlationId: null,
        expirationEpochSeconds: null,
        dismissedIds: [],
        badgeCount: null,
        retargetsToLiveSurfaceOwner: false,
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
        correlationId: null,
        expirationEpochSeconds: null,
        dismissedIds: [],
        badgeCount: null,
        retargetsToLiveSurfaceOwner: true,
        hideContent: false,
      },
    });

    expect(
      parsePushPayload({ title: "agent", body: "done", notificationId: "x".repeat(MAX_PUSH_ID_CHARS + 1) }),
    ).toEqual({ ok: false, error: "notification_id_too_long" });
    expect(
      parsePushPayload({
        title: "agent",
        body: "done",
        correlationId: "opaque-but-not-a-uuid",
      }),
    ).toEqual({ ok: false, error: "invalid_correlation_id" });
    expect(
      parsePushPayload({
        title: "agent",
        body: "done",
        correlationId: "4D02DE48-A21D-4BA1-97B5-42E9400EE09B",
      }),
    ).toMatchObject({
      ok: true,
      value: {
        correlationId: "4d02de48-a21d-4ba1-97b5-42e9400ee09b",
      },
    });
  });

  test("passes through known reply shapes and ignores unknown values", () => {
    const value = (replyShape: unknown) => {
      const parsed = parsePushPayload({ title: "agent", body: "done", replyShape });
      if (!parsed.ok) throw new Error(parsed.error);
      return parsed.value.replyShape;
    };

    expect(value("text")).toBe("text");
    expect(value("none")).toBe("none");
    expect(value(undefined)).toBeUndefined();
    expect(value("future-shape")).toBeUndefined();
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
        correlationId: null,
        expirationEpochSeconds: null,
        dismissedIds: ["n-1", "n-2"],
        badgeCount: 4,
        retargetsToLiveSurfaceOwner: false,
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

  test("rejects a present invalid expiration instead of minting a fresh TTL", () => {
    for (const expirationEpochSeconds of [null, -1, 1.5, "1700000120"]) {
      expect(
        parsePushPayload({
          title: "agent",
          body: "done",
          expirationEpochSeconds,
        }),
      ).toEqual({ ok: false, error: "invalid_expiration" });
    }
    const absent = parsePushPayload({ title: "agent", body: "done" });
    expect(absent.ok && absent.value.expirationEpochSeconds).toBeNull();
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
  test("the default send bound leaves room for a database lease", () => {
    expect(APNS_DEFAULT_MAX_DELIVERY_DURATION_MS).toBe(28_000);
  });

  test("provider JWT cache identity includes the team and signing key", async () => {
    const authorizations: string[] = [];

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
        authorizations.push(String(headers.authorization));
        return new FakeRequest();
      }
      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];
    const firstKeys = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const secondKeys = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const firstP8 = firstKeys.privateKey.export({ type: "pkcs8", format: "pem" }) as string;
    const secondP8 = secondKeys.privateKey.export({ type: "pkcs8", format: "pem" }) as string;
    const target = {
      deviceToken: "a".repeat(64),
      bundleId: "com.cmux.app",
      environment: "production",
    };

    await sendApnsNotification(
      { keyP8: firstP8, keyId: "SHARED-KID", teamId: "TEAM-A" },
      [target],
      { title: "agent", body: "done" },
      1_000,
      transport,
    );
    await sendApnsNotification(
      { keyP8: secondP8, keyId: "SHARED-KID", teamId: "TEAM-B" },
      [target],
      { title: "agent", body: "done" },
      1_000,
      transport,
    );

    const claims = authorizations.map((authorization) => {
      const jwt = authorization.replace(/^bearer /, "");
      const payload = jwt.split(".")[1]!;
      return JSON.parse(
        Buffer.from(payload.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8"),
      ) as { iss: string };
    });
    expect(claims.map((claim) => claim.iss)).toEqual(["TEAM-A", "TEAM-B"]);
  });

  test("sanitizes malformed signing credentials into per-target failures", async () => {
    let connections = 0;
    const transport = {
      connect: () => {
        connections += 1;
        throw new Error("transport must not be reached");
      },
    } as unknown as Parameters<typeof sendApnsNotification>[4];

    const results = await sendApnsNotification(
      {
        keyP8: "definitely not a private key",
        keyId: "BROKEN-KID",
        teamId: "TEAM456",
      },
      [
        {
          deviceToken: "a".repeat(64),
          bundleId: "com.cmux.app",
          environment: "production",
        },
        {
          deviceToken: "b".repeat(64),
          bundleId: "com.cmux.app",
          environment: "corrupt",
        },
      ],
      { title: "agent", body: "done" },
      1_000,
      transport,
    );

    expect(results).toEqual([
      {
        deviceToken: "a".repeat(64),
        status: 503,
        reason: "provider_auth_unavailable",
        prune: false,
      },
      {
        deviceToken: "b".repeat(64),
        status: 400,
        reason: "invalid_stored_environment",
        prune: true,
      },
    ]);
    expect(JSON.stringify(results)).not.toContain("private key");
    expect(connections).toBe(0);
  });

  test("defers 429 and 503 responses instead of clamping and hammering", async () => {
    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    for (const status of [429, 503]) {
      let requests = 0;
      let inProcessDelays = 0;
      class FakeRequest extends EventEmitter {
        setTimeout() {
          return this;
        }
        close() {
          return this;
        }
        end() {
          requests += 1;
          this.emit("response", {
            ":status": status,
            "retry-after": "30",
          });
          this.emit("data", Buffer.from(JSON.stringify({
            reason: status === 429 ? "TooManyRequests" : "ServiceUnavailable",
          })));
          this.emit("end");
          return this;
        }
      }
      class FakeSession extends EventEmitter {
        request() {
          return new FakeRequest();
        }
        close() {}
      }
      const transport = {
        connect: () => new FakeSession(),
      } as unknown as Parameters<typeof sendApnsNotification>[4];

      const results = await sendApnsNotificationReliably(
        {
          keyP8: p8,
          keyId: `RETRY-AFTER-${status}`,
          teamId: "TEAM456",
        },
        [{
          deviceToken: "a".repeat(64),
          bundleId: "com.cmux.app",
          environment: "production",
        }],
        {
          title: "agent",
          body: "done",
          expirationEpochSeconds: Math.floor(Date.now() / 1_000) + 120,
        },
        {
          retryDelay: async () => {
            inProcessDelays += 1;
          },
        },
        1_000,
        transport,
      );

      expect(requests).toBe(1);
      expect(inProcessDelays).toBe(0);
      const expectedRetryAfter = status === 503
        ? APNS_SERVER_ERROR_RETRY_SECONDS
        : 30;
      expect(results[0]?.retryAfterSeconds).toBe(expectedRetryAfter);
      expect(summarizeApnsSendResults(results)).toMatchObject({
        transientFailures: 1,
        retryAfterSeconds: expectedRetryAfter,
      });
    }
  });

  test("429 without Retry-After gets a bounded deferred retry", async () => {
    let requests = 0;
    let inProcessDelays = 0;
    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }
      close() {
        return this;
      }
      end() {
        requests += 1;
        this.emit("response", { ":status": 429 });
        this.emit("data", Buffer.from(JSON.stringify({
          reason: "TooManyRequests",
        })));
        this.emit("end");
        return this;
      }
    }
    class FakeSession extends EventEmitter {
      request() {
        return new FakeRequest();
      }
      close() {}
    }
    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];
    const { privateKey } = crypto.generateKeyPairSync(
      "ec",
      { namedCurve: "P-256" },
    );
    const p8 = privateKey.export({
      type: "pkcs8",
      format: "pem",
    }) as string;

    const results = await sendApnsNotificationReliably(
      { keyP8: p8, keyId: "KID-429-FALLBACK", teamId: "TEAM456" },
      [{
        deviceToken: "a".repeat(64),
        bundleId: "com.cmux.app",
        environment: "production",
      }],
      {
        title: "agent",
        body: "done",
        expirationEpochSeconds: Math.floor(Date.now() / 1_000) + 120,
      },
      {
        retryDelay: async () => {
          inProcessDelays += 1;
        },
      },
      1_000,
      transport,
    );

    expect(requests).toBe(1);
    expect(inProcessDelays).toBe(0);
    expect(results[0]).toMatchObject({
      status: 429,
      retryAfterSeconds: APNS_RATE_LIMIT_FALLBACK_SECONDS,
      prune: false,
    });
  });

  test("5xx without Retry-After waits fifteen minutes beyond event freshness", async () => {
    let requests = 0;
    let inProcessDelays = 0;
    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }
      close() {
        return this;
      }
      end() {
        requests += 1;
        this.emit("response", { ":status": 503 });
        this.emit("data", Buffer.from(JSON.stringify({
          reason: "ServiceUnavailable",
        })));
        this.emit("end");
        return this;
      }
    }
    class FakeSession extends EventEmitter {
      request() {
        return new FakeRequest();
      }
      close() {}
    }
    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];
    const { privateKey } = crypto.generateKeyPairSync(
      "ec",
      { namedCurve: "P-256" },
    );
    const p8 = privateKey.export({
      type: "pkcs8",
      format: "pem",
    }) as string;

    const results = await sendApnsNotificationReliably(
      { keyP8: p8, keyId: "KID-503-DEFER", teamId: "TEAM456" },
      [{
        deviceToken: "a".repeat(64),
        bundleId: "com.cmux.app",
        environment: "production",
      }],
      {
        title: "agent",
        body: "done",
        expirationEpochSeconds: Math.floor(Date.now() / 1_000) + 120,
      },
      {
        retryDelay: async () => {
          inProcessDelays += 1;
        },
      },
      1_000,
      transport,
    );

    expect(requests).toBe(1);
    expect(inProcessDelays).toBe(0);
    expect(results[0]).toMatchObject({
      status: 503,
      retryAfterSeconds: APNS_SERVER_ERROR_RETRY_SECONDS,
      prune: false,
    });
  });

  test("retries only unresolved devices after a partial connection failure", async () => {
    const attemptsByToken = new Map<string, number>();
    const capturedHeaders: http2.OutgoingHttpHeaders[] = [];

    class FakeRequest extends EventEmitter {
      constructor(private readonly status: number) {
        super();
      }
      setTimeout() {
        return this;
      }
      close() {
        return this;
      }
      end() {
        if (this.status === 0) {
          this.emit("error", new Error("connection reset"));
          return this;
        }
        this.emit("response", { ":status": this.status });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      request(headers: http2.OutgoingHttpHeaders) {
        capturedHeaders.push(headers);
        const deviceToken = String(headers[":path"]).split("/").at(-1)!;
        const attempt = (attemptsByToken.get(deviceToken) ?? 0) + 1;
        attemptsByToken.set(deviceToken, attempt);
        const status = deviceToken.startsWith("a") || attempt > 1 ? 200 : 0;
        return new FakeRequest(status);
      }
      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];
    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;
    const correlationId = "4d02de48-a21d-4ba1-97b5-42e9400ee09b";

    const results = await sendApnsNotificationReliably(
      { keyP8: p8, keyId: "KID-RETRY-PARTIAL", teamId: "TEAM456" },
      [
        { deviceToken: "a".repeat(64), bundleId: "com.cmux.app", environment: "production" },
        { deviceToken: "b".repeat(64), bundleId: "com.cmux.app", environment: "production" },
      ],
      {
        title: "agent",
        body: "done",
        correlationId,
        expirationEpochSeconds: 1_700_000_120,
      },
      {
        maxAttempts: 2,
        nowEpochSeconds: () => 1_700_000_000,
        retryDelay: async () => {},
      },
      1000,
      transport,
    );

    expect(results.map((result) => result.status)).toEqual([200, 200]);
    expect(attemptsByToken.get("a".repeat(64))).toBe(1);
    expect(attemptsByToken.get("b".repeat(64))).toBe(2);
    expect(capturedHeaders.every((headers) => headers["apns-collapse-id"] === correlationId)).toBe(true);
    expect(capturedHeaders.every((headers) => headers["apns-id"] === correlationId)).toBe(true);
    expect(capturedHeaders.every((headers) => headers["apns-expiration"] === "1700000120")).toBe(true);
  });

  test("refreshes once for expired provider token but never retries invalid credentials", async () => {
    const { privateKey } = crypto.generateKeyPairSync(
      "ec",
      { namedCurve: "P-256" },
    );
    const p8 = privateKey.export({
      type: "pkcs8",
      format: "pem",
    }) as string;
    const target = {
      deviceToken: "a".repeat(64),
      bundleId: "com.cmux.app",
      environment: "production",
    };

    for (const reason of [
      "ExpiredProviderToken",
      "InvalidProviderToken",
    ] as const) {
      const authorizations: string[] = [];
      let requests = 0;
      class FakeRequest extends EventEmitter {
        setTimeout() {
          return this;
        }
        close() {
          return this;
        }
        end() {
          requests += 1;
          const succeeds = reason === "ExpiredProviderToken" && requests === 2;
          this.emit("response", { ":status": succeeds ? 200 : 403 });
          if (!succeeds) {
            this.emit("data", Buffer.from(JSON.stringify({ reason })));
          }
          this.emit("end");
          return this;
        }
      }
      class FakeSession extends EventEmitter {
        request(headers: http2.OutgoingHttpHeaders) {
          authorizations.push(String(headers.authorization));
          return new FakeRequest();
        }
        close() {}
      }
      const transport = {
        connect: () => new FakeSession(),
      } as unknown as Parameters<typeof sendApnsNotification>[4];

      const results = await sendApnsNotificationReliably(
        {
          keyP8: p8,
          keyId: `KID-${reason}`,
          teamId: "TEAM456",
        },
        [target],
        {
          title: "agent",
          body: "done",
          expirationEpochSeconds: Math.floor(Date.now() / 1_000) + 120,
        },
        {
          maxAttempts: 3,
          retryDelay: async () => {},
        },
        1_000,
        transport,
      );

      if (reason === "ExpiredProviderToken") {
        expect(requests).toBe(2);
        expect(results[0]?.status).toBe(200);
        expect(authorizations).toHaveLength(2);
        expect(authorizations[1]).not.toBe(authorizations[0]);
      } else {
        expect(requests).toBe(1);
        expect(results[0]).toMatchObject({
          status: 403,
          reason: "InvalidProviderToken",
          prune: false,
        });
        expect(summarizeApnsSendResults(results)).toMatchObject({
          transientFailures: 0,
          permanentFailures: 1,
        });
      }
    }
  });

  test("a deferred target never blocks other targets' immediate recovery", async () => {
    const { privateKey } = crypto.generateKeyPairSync(
      "ec",
      { namedCurve: "P-256" },
    );
    const p8 = privateKey.export({
      type: "pkcs8",
      format: "pem",
    }) as string;
    const correlationId = "b4b436c4-ee9b-473d-a36c-239a3dd02412";

    for (const deferredStatus of [429, 503]) {
      const attempts = new Map<string, number>();
      class FakeRequest extends EventEmitter {
        constructor(
          private readonly deviceToken: string,
          private readonly attempt: number,
        ) {
          super();
        }
        setTimeout() {
          return this;
        }
        close() {
          return this;
        }
        end() {
          if (this.deviceToken.startsWith("a")) {
            this.emit("response", { ":status": deferredStatus });
            this.emit("data", Buffer.from(JSON.stringify({
              reason: deferredStatus === 429
                ? "TooManyRequests"
                : "ServiceUnavailable",
            })));
          } else if (
            this.deviceToken.startsWith("b")
            && this.attempt === 1
          ) {
            this.emit("error", new Error("connection reset"));
            return this;
          } else if (
            this.deviceToken.startsWith("c")
            && this.attempt === 1
          ) {
            this.emit("response", { ":status": 403 });
            this.emit("data", Buffer.from(JSON.stringify({
              reason: "ExpiredProviderToken",
            })));
          } else {
            this.emit("response", { ":status": 200 });
          }
          this.emit("end");
          return this;
        }
      }
      class FakeSession extends EventEmitter {
        request(headers: http2.OutgoingHttpHeaders) {
          const token = String(headers[":path"]).split("/").at(-1)!;
          const attempt = (attempts.get(token) ?? 0) + 1;
          attempts.set(token, attempt);
          expect(headers["apns-id"]).toBe(correlationId);
          return new FakeRequest(token, attempt);
        }
        close() {}
      }
      const transport = {
        connect: () => new FakeSession(),
      } as unknown as Parameters<typeof sendApnsNotification>[4];

      const results = await sendApnsNotificationReliably(
        {
          keyP8: p8,
          keyId: `KID-MIXED-${deferredStatus}`,
          teamId: "TEAM456",
        },
        [
          {
            deviceToken: "a".repeat(64),
            bundleId: "com.cmux.app",
            environment: "production",
          },
          {
            deviceToken: "b".repeat(64),
            bundleId: "dev.cmux.ios.push1",
            environment: "sandbox",
          },
          {
            deviceToken: "c".repeat(64),
            bundleId: "com.cmux.app",
            environment: "production",
          },
        ],
        {
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds: Math.floor(Date.now() / 1_000) + 120,
        },
        {
          maxAttempts: 3,
          retryDelay: async () => {},
        },
        1_000,
        transport,
      );

      expect(results.map((result) => result.status)).toEqual([
        deferredStatus,
        200,
        200,
      ]);
      expect(attempts.get("a".repeat(64))).toBe(1);
      expect(attempts.get("b".repeat(64))).toBe(2);
      expect(attempts.get("c".repeat(64))).toBe(2);
      expect(results[0]?.retryAfterSeconds).toBe(
        deferredStatus === 503
          ? APNS_SERVER_ERROR_RETRY_SECONDS
          : APNS_RATE_LIMIT_FALLBACK_SECONDS,
      );
      expect(summarizeApnsSendResults(results)).toMatchObject({
        sent: 2,
        transientFailures: 1,
        permanentFailures: 0,
      });
    }
  });

  test("leaves sent zero as a failure after the retry TTL is exhausted", async () => {
    let requests = 0;

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }
      close() {
        return this;
      }
      end() {
        requests += 1;
        this.emit("response", { ":status": 503 });
        this.emit("data", Buffer.from(JSON.stringify({ reason: "ServiceUnavailable" })));
        this.emit("end");
        return this;
      }
    }
    class FakeSession extends EventEmitter {
      request() {
        return new FakeRequest();
      }
      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];
    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const p8 = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    const results = await sendApnsNotificationReliably(
      { keyP8: p8, keyId: "KID-RETRY-TTL", teamId: "TEAM456" },
      [{ deviceToken: "a".repeat(64), bundleId: "com.cmux.app", environment: "production" }],
      {
        title: "agent",
        body: "done",
        correlationId: "527e7ed5-b70d-45d8-a78e-fd032ae61ff5",
        expirationEpochSeconds: 1_700_000_000,
      },
      {
        maxAttempts: 3,
        nowEpochSeconds: () => 1_700_000_000,
        retryDelay: async () => {},
      },
      1000,
      transport,
    );

    expect(summarizeApnsSendResults(results).sent).toBe(0);
    // Expired before the first attempt: never enqueue a stale alert at APNs.
    expect(requests).toBe(0);
  });

  test("starts sandbox and production host groups concurrently", async () => {
    const sandboxHost = apnsHostForEnvironment("sandbox");
    const productionHost = apnsHostForEnvironment("production")!;
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
        { deviceToken: "b".repeat(64), bundleId: "com.cmux.app", environment: "production" },
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
      { deviceToken: "a".repeat(64), bundleId: "dev.cmux.ios.push1", status: 200, reason: undefined, prune: false },
      { deviceToken: "b".repeat(64), bundleId: "com.cmux.app", status: 200, reason: undefined, prune: false },
    ]);
    expect(closed).toEqual([productionHost, sandboxHost]);
  });

  test("bootstraps one authenticated stream then honors the remote stream limit for 200 targets", async () => {
    const remoteLimit = 3;
    let active = 0;
    let maximumActive = 0;
    let requestCount = 0;
    let bootstrapComplete = false;
    let requestsBeforeBootstrap = 0;

    class FakeRequest extends EventEmitter {
      constructor(private readonly ordinal: number) {
        super();
      }

      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        active += 1;
        maximumActive = Math.max(maximumActive, active);
        if (!bootstrapComplete) requestsBeforeBootstrap += 1;
        this.emit("response", { ":status": 200 });
        setTimeout(() => {
          active -= 1;
          if (this.ordinal === 1) bootstrapComplete = true;
          this.emit("end");
        }, 1);
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      readonly remoteSettings = {
        maxConcurrentStreams: remoteLimit,
      };

      request() {
        requestCount += 1;
        return new FakeRequest(requestCount);
      }

      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];
    const { privateKey } = crypto.generateKeyPairSync(
      "ec",
      { namedCurve: "P-256" },
    );
    const p8 = privateKey.export({
      type: "pkcs8",
      format: "pem",
    }) as string;
    const targets = Array.from({ length: 200 }, (_, index) => ({
      deviceToken: index.toString(16).padStart(64, "0"),
      bundleId: "com.cmux.app",
      environment: "production",
    }));

    const results = await sendApnsNotification(
      { keyP8: p8, keyId: "KID-STREAMS", teamId: "TEAM456" },
      targets,
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    expect(results).toHaveLength(200);
    expect(results.every((result) => result.status === 200)).toBe(true);
    expect(requestCount).toBe(200);
    expect(requestsBeforeBootstrap).toBe(1);
    expect(maximumActive).toBeLessThanOrEqual(remoteLimit);
  });

  test("reuses one authenticated APNs connection across logical events", async () => {
    let connections = 0;
    let closes = 0;
    let requests = 0;

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        requests += 1;
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      readonly remoteSettings = { maxConcurrentStreams: 8 };

      request() {
        return new FakeRequest();
      }

      close() {
        closes += 1;
      }
    }

    const transport = {
      connect: () => {
        connections += 1;
        return new FakeSession();
      },
    } as unknown as Parameters<typeof sendApnsNotification>[4];
    const pool = createApnsSessionPool(transport!, 60_000);
    const { privateKey } = crypto.generateKeyPairSync(
      "ec",
      { namedCurve: "P-256" },
    );
    const p8 = privateKey.export({
      type: "pkcs8",
      format: "pem",
    }) as string;
    const config = {
      keyP8: p8,
      keyId: "KID-POOL",
      teamId: "TEAM456",
    };
    const target = {
      deviceToken: "a".repeat(64),
      bundleId: "com.cmux.app",
      environment: "production",
    };

    await sendApnsNotification(
      config,
      [target],
      { title: "agent", body: "first" },
      1_000,
      transport,
      false,
      pool,
    );
    await sendApnsNotification(
      config,
      [target],
      { title: "agent", body: "second" },
      1_000,
      transport,
      false,
      pool,
    );

    expect(connections).toBe(1);
    expect(requests).toBe(2);
    expect(closes).toBe(0);
    pool.closeAll();
    expect(closes).toBe(1);
  });

  test("abandons a pooled operation whose queue wait exceeds its deadline", async () => {
    class FakeSession extends EventEmitter {
      request(): never {
        throw new Error("request should not be reached");
      }

      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof createApnsSessionPool>[0];
    const pool = createApnsSessionPool(transport, 60_000);
    let releaseFirst!: () => void;
    let markFirstStarted!: () => void;
    const firstStarted = new Promise<void>((resolve) => {
      markFirstStarted = resolve;
    });
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const first = pool.withSession(
      "api.push.apple.com",
      "credential",
      async () => {
        markFirstStarted();
        await firstGate;
        return "first";
      },
      Date.now() + 1_000,
    );
    await firstStarted;

    let secondExecuted = false;
    const second = pool.withSession(
      "api.push.apple.com",
      "credential",
      async () => {
        secondExecuted = true;
        return "second";
      },
      Date.now() + 10,
    );

    await expect(second).rejects.toThrow(
      "APNs session acquisition deadline exceeded",
    );
    releaseFirst();
    await first;
    await Promise.resolve();
    expect(secondExecuted).toBe(false);
    pool.closeAll();
  });

  test("replaces a pooled APNs connection after GOAWAY", async () => {
    const sessions: FakeSession[] = [];
    let requests = 0;

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        requests += 1;
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      readonly remoteSettings = { maxConcurrentStreams: 8 };

      request() {
        return new FakeRequest();
      }

      close() {}
    }

    const transport = {
      connect: () => {
        const session = new FakeSession();
        sessions.push(session);
        return session;
      },
    } as unknown as Parameters<typeof sendApnsNotification>[4];
    const pool = createApnsSessionPool(transport!, 60_000);
    const { privateKey } = crypto.generateKeyPairSync(
      "ec",
      { namedCurve: "P-256" },
    );
    const p8 = privateKey.export({
      type: "pkcs8",
      format: "pem",
    }) as string;
    const config = {
      keyP8: p8,
      keyId: "KID-GOAWAY",
      teamId: "TEAM456",
    };
    const target = {
      deviceToken: "a".repeat(64),
      bundleId: "com.cmux.app",
      environment: "production",
    };

    await sendApnsNotification(
      config,
      [target],
      { title: "agent", body: "first" },
      1_000,
      transport,
      false,
      pool,
    );
    sessions[0]!.emit("goaway", 0, 1, Buffer.alloc(0));
    await sendApnsNotification(
      config,
      [target],
      { title: "agent", body: "second" },
      1_000,
      transport,
      false,
      pool,
    );

    expect(sessions).toHaveLength(2);
    expect(requests).toBe(2);
    pool.closeAll();
  });

  test("rejects 4097-byte Unicode payloads locally but sends 4096 bytes", async () => {
    let requests = 0;

    class FakeRequest extends EventEmitter {
      setTimeout() {
        return this;
      }

      close() {
        return this;
      }

      end() {
        requests += 1;
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }

    class FakeSession extends EventEmitter {
      request() {
        return new FakeRequest();
      }

      close() {}
    }

    const transport = {
      connect: () => new FakeSession(),
    } as unknown as Parameters<typeof sendApnsNotification>[4];
    const { privateKey } = crypto.generateKeyPairSync(
      "ec",
      { namedCurve: "P-256" },
    );
    const p8 = privateKey.export({
      type: "pkcs8",
      format: "pem",
    }) as string;
    const target = {
      deviceToken: "a".repeat(64),
      bundleId: "com.cmux.app",
      environment: "production",
    };
    const inputAtSize = (targetBytes: number) => {
      const baseInput = { title: "agent", body: "a" };
      const baseBytes = Buffer.byteLength(
        JSON.stringify(buildApnsPayload(baseInput)),
      );
      const remaining = targetBytes - baseBytes + 1;
      const body =
        "🙂".repeat(Math.floor(remaining / 4))
        + "a".repeat(remaining % 4);
      const input = { ...baseInput, body };
      expect(
        Buffer.byteLength(JSON.stringify(buildApnsPayload(input))),
      ).toBe(targetBytes);
      return input;
    };

    const accepted = await sendApnsNotification(
      { keyP8: p8, keyId: "KID-SIZE", teamId: "TEAM456" },
      [target],
      inputAtSize(APNS_MAX_PAYLOAD_BYTES),
      1000,
      transport,
    );
    const rejected = await sendApnsNotification(
      { keyP8: p8, keyId: "KID-SIZE", teamId: "TEAM456" },
      [target],
      inputAtSize(APNS_MAX_PAYLOAD_BYTES + 1),
      1000,
      transport,
    );

    expect(requests).toBe(1);
    expect(accepted).toEqual([{
      deviceToken: target.deviceToken,
      bundleId: target.bundleId,
      status: 200,
      reason: undefined,
      prune: false,
    }]);
    expect(rejected).toEqual([{
      deviceToken: target.deviceToken,
      status: 413,
      reason: "PayloadTooLarge",
      prune: false,
    }]);
  });

  test("keeps healthy host results when another host cannot connect", async () => {
    const sandboxHost = apnsHostForEnvironment("sandbox");
    const productionHost = apnsHostForEnvironment("production")!;
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
        { deviceToken: "b".repeat(64), bundleId: "com.cmux.app", environment: "production" },
      ],
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    expect(results).toEqual([
      { deviceToken: "a".repeat(64), bundleId: "dev.cmux.ios.push1", status: 0, reason: "connection_error", prune: false },
      { deviceToken: "b".repeat(64), bundleId: "com.cmux.app", status: 200, reason: undefined, prune: false },
    ]);
    expect(closed).toEqual([productionHost]);
  });

  test("keeps same-host successes when another request fails to start", async () => {
    const productionHost = apnsHostForEnvironment("production")!;
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
        { deviceToken: "a".repeat(64), bundleId: "com.cmux.app", environment: "production" },
        { deviceToken: "b".repeat(64), bundleId: "dev.cmux.app.beta", environment: "production" },
      ],
      { title: "agent", body: "done" },
      1000,
      transport,
    );

    expect(results).toEqual([
      { deviceToken: "a".repeat(64), bundleId: "com.cmux.app", status: 200, reason: undefined, prune: false },
      { deviceToken: "b".repeat(64), bundleId: "dev.cmux.app.beta", status: 0, reason: "request failed", prune: false },
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
      [{ deviceToken: "a".repeat(64), bundleId: "com.cmux.app", environment: "production" }],
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
      [{ deviceToken: "a".repeat(64), bundleId: "com.cmux.app", environment: "production" }],
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
      [{ deviceToken: "a".repeat(64), bundleId: "com.cmux.app", environment: "production" }],
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

  test("notify push explicitly requests immediate priority", async () => {
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
      [{ deviceToken: "a".repeat(64), bundleId: "com.cmux.app", environment: "production" }],
      { title: "agent", body: "done", badgeCount: 2 },
      1000,
      transport,
    );

    expect(capturedHeaders).toHaveLength(1);
    expect(capturedHeaders[0]["apns-priority"]).toBe("10");
  });
});

import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import { describe, expect, test } from "bun:test";
import { buildApnsPayload, CMUX_APNS_CATEGORY } from "../services/apns/payload";
import { parsePushPayload } from "../services/apns/routePolicy";
import { APNS_MAX_PAYLOAD_BYTES, sendApnsNotification } from "../services/apns/sender";

const correlationId = "62dbd6e3-f8ef-4d40-bafc-88b2ecc3dbe7";
const bundleID = "dev.cmux.ios.e2en12";
function envelope(installationID = "installation-one", keyID = "key-one", bytes = 1800) {
  return {
    version: 2,
    installationID,
    keyID,
    encapsulatedKey: Buffer.alloc(32, 7).toString("base64"),
    senderKeyID: "mac-key",
    ciphertext: Buffer.alloc(bytes, 3).toString("base64"),
    tuple: {
      accountID: "account-one",
      iosBuildID: bundleID,
      iosInstallationID: installationID,
      macDeviceID: "mac-one",
      macInstanceTag: "e2en12",
      macBuildID: "com.cmuxterm.app.debug.e2en12",
    },
  };
}

function wire(overrides: Record<string, unknown> = {}) {
  return {
    kind: "notify",
    correlationId,
    macDeviceId: "mac-one",
    macInstanceTag: "e2en12",
    encryptedPayloads: [envelope()],
    ...overrides,
  };
}

function parsedWire(overrides: Record<string, unknown> = {}) {
  const result = parsePushPayload(wire(overrides));
  if (!result.ok) throw new Error(result.error);
  return result.value;
}

describe("encrypted production APNs boundary", () => {
  test("preserves the context needed by the extension without terminal content or an unauthenticated reply key", () => {
    const body = buildApnsPayload({
      ...parsedWire(),
      macPushPublicKey: "untrusted-server-key",
    }) as { aps: Record<string, unknown>; cmux: Record<string, unknown> };
    expect(body.aps["mutable-content"]).toBe(1);
    expect(body.aps.category).toBe(CMUX_APNS_CATEGORY);
    expect(body.cmux).toEqual({
      encryptedPayloads: [envelope()], macDeviceId: "mac-one", macInstanceTag: "e2en12", correlationId,
    });
    expect(body.cmux.macPushPublicKey).toBeUndefined();
    expect(body.cmux.workspaceId).toBeUndefined();
    expect(body.cmux.surfaceId).toBeUndefined();
  });

  test("encrypted dismiss uses ciphertext without requiring or publishing plaintext notification IDs", () => {
    const parsed = parsedWire({ kind: "dismiss", badgeCount: 0 });
    const body = buildApnsPayload(parsed) as { aps: Record<string, unknown>; cmux: Record<string, unknown> };
    expect(body.aps).toEqual({
      "content-available": 1,
      "mutable-content": 1,
      alert: { title: "", body: "" },
      badge: 0,
    });
    expect(body.cmux.encryptedPayloads).toEqual([envelope()]);
    expect(body.cmux.dismissedIds).toBeUndefined();
    expect(body.aps.alert).toEqual({ title: "", body: "" });
  });

  test("rejects plaintext fields and malformed or duplicate encrypted recipients", () => {
    for (const key of ["title", "subtitle", "body", "workspaceId", "surfaceId", "notificationIds"]) {
      expect(parsePushPayload(wire({ [key]: "E2E-SENTINEL-MUST-NOT-LEAK" })).ok).toBe(false);
    }
    for (const bad of [
      { ...envelope(), version: 3 },
      { ...envelope(), nonce: "bad" },
      { ...envelope(), ciphertext: "not-base64" },
      { ...envelope(), encapsulatedKey: Buffer.alloc(31).toString("base64") },
      { ...envelope(), text: "E2E-SENTINEL-MUST-NOT-LEAK" },
      { ...envelope(), tuple: { ...envelope().tuple, accountID: "" } },
      { ...envelope(), installationID: "someone-else" },
    ]) expect(parsePushPayload(wire({ encryptedPayloads: [bad] })).ok).toBe(false);
    expect(parsePushPayload(wire({ encryptedPayloads: [envelope(), envelope()] })).ok).toBe(false);
  });

  test("bounds APNs independently per device and sends only that installation's ciphertext", async () => {
    const requests: Array<{ topic: unknown; body: Buffer }> = [];
    class Request extends EventEmitter {
      constructor(private readonly topic: unknown) { super(); }
      setTimeout() { return this; }
      close() { return this; }
      end(body: Buffer) {
        requests.push({ topic: this.topic, body });
        this.emit("response", { ":status": 200 });
        this.emit("end");
        return this;
      }
    }
    class Session extends EventEmitter {
      request(headers: Record<string, unknown>) { return new Request(headers["apns-topic"]); }
      close() {}
    }
    const transport = { connect: () => new Session() } as unknown as Parameters<typeof sendApnsNotification>[4];
    const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const config = {
      keyP8: privateKey.export({ type: "pkcs8", format: "pem" }) as string,
      keyId: "test-provider", teamId: "test-team",
    };
    const targets = [
      { deviceToken: "a".repeat(64), bundleId: bundleID, environment: "sandbox", installationId: "installation-one", pushKeyId: "key-one" },
      { deviceToken: "b".repeat(64), bundleId: bundleID, environment: "sandbox", installationId: "installation-two", pushKeyId: "key-two" },
    ];
    const input = parsedWire({ encryptedPayloads: [envelope(), envelope("installation-two", "key-two")] });
    expect(Buffer.byteLength(JSON.stringify(buildApnsPayload(input)))).toBeGreaterThan(APNS_MAX_PAYLOAD_BYTES);
    const result = await sendApnsNotification(config, targets, input, 1000, transport);
    expect(result.map((entry) => entry.status)).toEqual([200, 200]);
    expect(requests).toHaveLength(2);
    for (let index = 0; index < requests.length; index++) {
      const request = requests[index]!;
      expect(request.body.byteLength).toBeLessThanOrEqual(APNS_MAX_PAYLOAD_BYTES);
      expect(request.topic).toBe(bundleID);
      const payload = JSON.parse(request.body.toString());
      expect(payload.cmux.encryptedPayloads).toHaveLength(1);
      expect(payload.cmux.encryptedPayloads[0].installationID).toBe(targets[index]!.installationId);
    }
    requests.length = 0;
    const stale = await sendApnsNotification(config, [{ ...targets[0]!, pushKeyId: "rotated" }], input, 1000, transport);
    expect(stale[0]?.reason).toBe("push_recipient_key_changed");
    expect(requests).toHaveLength(0);
    const wrongBuild = await sendApnsNotification(config, [{ ...targets[0]!, bundleId: "dev.cmux.ios.other" }], input, 1000, transport);
    expect(wrongBuild[0]?.reason).toBe("push_recipient_key_changed");
    expect(requests).toHaveLength(0);
  });
});

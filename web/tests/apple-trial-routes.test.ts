import { beforeEach, describe, expect, mock, test } from "bun:test";
import { createHash, generateKeyPairSync, sign, type KeyObject } from "node:crypto";

import * as accountTokenModule from "../services/billing/apple/accountToken";
import * as appAttestModule from "../services/billing/apple/appAttest";
import * as trialStoreModule from "../services/billing/apple/trialStore";
import type { AttestKeyRow, TrialClaimRow } from "../services/billing/apple/trialStore";

// Route boundary for the trial device proof: POST /api/billing/apple/trial/
// challenge and /verify with the real App Attest verifier, DeviceCheck client
// and introductory-offer signer. Replaced: Stack auth, the database, Apple's
// DeviceCheck host (fetch), and the pinned App Attest root, by a locally
// generated root that signs a chain shaped like Apple's.

// Minimal DER and CBOR writers for the fixtures.
const der = (tag: number, body: Buffer): Buffer => {
  const length = body.length < 0x80
    ? Buffer.from([body.length])
    : body.length < 0x100 ? Buffer.from([0x81, body.length]) : Buffer.from([0x82, body.length >> 8, body.length & 0xff]);
  return Buffer.concat([Buffer.from([tag]), length, body]);
};
const seq = (...items: Buffer[]) => der(0x30, Buffer.concat(items));
const oid = (bytes: number[]) => der(0x06, Buffer.from(bytes));
const ECDSA_SHA256 = seq(oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]));
const name = (cn: string) => seq(der(0x31, seq(oid([0x55, 0x04, 0x03]), der(0x0c, Buffer.from(cn)))));
const utc = (date: Date) => der(0x17, Buffer.from(`${date.toISOString().slice(2, 19).replace(/[-:T]/g, "")}Z`));
const NONCE_OID = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02];
const BASIC_CONSTRAINTS_CA = seq(oid([0x55, 0x1d, 0x13]), der(0x01, Buffer.from([0xff])), der(0x04, seq(der(0x01, Buffer.from([0xff])))));

function certificate(input: { subject: string; issuer: string; key: KeyObject; issuerKey: KeyObject; serial: number; ca: boolean; nonce?: Buffer }): Buffer {
  const extensions = [
    ...(input.ca ? [BASIC_CONSTRAINTS_CA] : []),
    ...(input.nonce ? [seq(oid(NONCE_OID), der(0x04, seq(der(0xa1, der(0x04, input.nonce)))))] : []),
  ];
  const tbs = seq(
    der(0xa0, der(0x02, Buffer.from([2]))),
    der(0x02, Buffer.from([input.serial])),
    ECDSA_SHA256,
    name(input.issuer),
    seq(utc(new Date(Date.now() - 86_400_000)), utc(new Date(Date.now() + 86_400_000))),
    name(input.subject),
    input.key.export({ format: "der", type: "spki" }),
    ...(extensions.length ? [der(0xa3, seq(...extensions))] : []),
  );
  const signature = sign("sha256", tbs, input.issuerKey);
  return seq(tbs, ECDSA_SHA256, der(0x03, Buffer.concat([Buffer.from([0]), signature])));
}

type CborValue = number | string | Buffer | CborValue[] | Map<string, CborValue>;
function cbor(value: CborValue): Buffer {
  const head = (major: number, length: number) => length < 24
    ? Buffer.from([(major << 5) | length])
    : length < 0x100 ? Buffer.from([(major << 5) | 24, length]) : Buffer.from([(major << 5) | 25, length >> 8, length & 0xff]);
  if (typeof value === "number") return head(0, value);
  if (typeof value === "string") return Buffer.concat([head(3, Buffer.byteLength(value)), Buffer.from(value)]);
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(cbor)]);
  return Buffer.concat([head(5, value.size), ...[...value].flatMap(([key, item]) => [cbor(key), cbor(item)])]);
}

const sha256 = (...parts: Buffer[]) => createHash("sha256").update(Buffer.concat(parts)).digest();
const ec = () => generateKeyPairSync("ec", { namedCurve: "P-256" });
const rootKeys = ec();
const intermediateKeys = ec();
const ROOT_DER = certificate({ subject: "Test App Attestation Root CA", issuer: "Test App Attestation Root CA", key: rootKeys.publicKey, issuerKey: rootKeys.privateKey, serial: 1, ca: true });
const INTERMEDIATE_DER = certificate({ subject: "Test App Attestation CA 1", issuer: "Test App Attestation Root CA", key: intermediateKeys.publicKey, issuerKey: rootKeys.privateKey, serial: 2, ca: true });
const ROOT_PEM = `-----BEGIN CERTIFICATE-----\n${ROOT_DER.toString("base64").match(/.{1,64}/g)!.join("\n")}\n-----END CERTIFICATE-----`;

function devicePoint(key: KeyObject): Buffer {
  const jwk = key.export({ format: "jwk" });
  return Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x!, "base64url"), Buffer.from(jwk.y!, "base64url")]);
}

const PRODUCT_ID = "com.cmux.app.pro.trial.monthly";
function clientDataHash(challenge: string) {
  return sha256(Buffer.from(challenge), Buffer.from(PRODUCT_ID));
}

function attestation(deviceKeys: ReturnType<typeof ec>, challenge: string, appId = "7WLXT3NR37.com.cmux.app") {
  const keyId = sha256(devicePoint(deviceKeys.publicKey));
  const authData = Buffer.concat([
    sha256(Buffer.from(appId)), Buffer.from([0x40]), Buffer.alloc(4),
    Buffer.from("appattestdevelop"), Buffer.from([0, keyId.length]), keyId, Buffer.from([0xa0]),
  ]);
  const nonce = sha256(authData, clientDataHash(challenge));
  const leaf = certificate({ subject: keyId.toString("hex"), issuer: "Test App Attestation CA 1", key: deviceKeys.publicKey, issuerKey: intermediateKeys.privateKey, serial: 3, ca: false, nonce });
  const object = cbor(new Map<string, CborValue>([
    ["fmt", "apple-appattest"],
    ["attStmt", new Map<string, CborValue>([["x5c", [leaf, INTERMEDIATE_DER]], ["receipt", Buffer.from("receipt")]])],
    ["authData", authData],
  ]));
  return { keyId: keyId.toString("base64"), attestation: object.toString("base64") };
}

function assertion(deviceKeys: ReturnType<typeof ec>, challenge: string, counter: number) {
  const authenticatorData = Buffer.concat([sha256(Buffer.from("7WLXT3NR37.com.cmux.app")), Buffer.from([0x40]), Buffer.from([0, 0, 0, counter])]);
  const signature = sign("sha256", sha256(authenticatorData, clientDataHash(challenge)), deviceKeys.privateKey);
  return cbor(new Map<string, CborValue>([["signature", signature], ["authenticatorData", authenticatorData]])).toString("base64");
}

// Injected boundaries.

type TestUser = { id: string; isAnonymous: boolean; primaryEmail: string | null; primaryEmailVerified: boolean };
let currentUser: TestUser = { id: "user-a", isAnonymous: false, primaryEmail: "a@example.com", primaryEmailVerified: true };
mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({ getUser: async () => currentUser }),
}));

const realAppAttest = { ...appAttestModule };
mock.module("../services/billing/apple/appAttest", () => ({
  ...realAppAttest,
  verifyAttestation: (input: Parameters<typeof appAttestModule.verifyAttestation>[0]) =>
    realAppAttest.verifyAttestation({ ...input, rootCertificatePem: ROOT_PEM }),
}));

let accountOffered = true;
const realAccountToken = { ...accountTokenModule };
mock.module("../services/billing/apple/accountToken", () => ({
  ...realAccountToken,
  appleAccountTokenResponse: async () => (accountOffered ? { trial: { offered: true } } : {}),
}));

const challenges = new Map<string, { userId: string; expiresAt: Date }>();
const keys = new Map<string, AttestKeyRow>();
const claims = new Map<string, TrialClaimRow>();
mock.module("../services/billing/apple/trialStore", () => ({
  ...trialStoreModule,
  databaseTrialStore: () => ({
    issueChallenge: async (userId: string, challenge: string, expiresAt: Date) => {
      challenges.set(challenge, { userId, expiresAt });
    },
    consumeChallenge: async (userId: string, challenge: string, now: Date) => {
      const row = challenges.get(challenge);
      challenges.delete(challenge);
      return Boolean(row && row.userId === userId && row.expiresAt > now);
    },
    attestKey: async (keyId: string) => keys.get(keyId) ?? null,
    bindAttestKey: async (key: Omit<AttestKeyRow, "signCount">) => {
      if (!keys.has(key.keyId)) keys.set(key.keyId, { ...key, signCount: 0 });
      return keys.get(key.keyId)!.userId;
    },
    advanceSignCount: async (keyId: string, signCount: number) => {
      const key = keys.get(keyId)!;
      if (key.signCount >= signCount) return false;
      keys.set(keyId, { ...key, signCount });
      return true;
    },
    claim: async (userId: string) => claims.get(userId) ?? null,
    recordVerifiedClaim: async (userId: string, keyId: string, deviceCheckToken: string) => {
      if (claims.get(userId)?.status === "started") return false;
      claims.set(userId, { ...emptyClaim, userId, keyId, deviceCheckToken, status: "verified" });
      return true;
    },
    markDeviceMarkAttempted: async (userId: string, now: Date) => {
      claims.set(userId, { ...claims.get(userId)!, deviceMarkAttemptedAt: now });
    },
    markDeviceMarked: async (userId: string, now: Date) => {
      claims.set(userId, { ...claims.get(userId)!, deviceMarkedAt: now });
    },
    markDeviceReused: async (userId: string) => {
      const claim = claims.get(userId)!;
      if (claim.status === "started" && !claim.deviceMarkAttemptedAt && !claim.deviceMarkedAt) claims.set(userId, { ...claim, status: "device_reused" });
    },
    markGranted: async (userId: string, now: Date) => {
      claims.set(userId, { ...claims.get(userId)!, grantedAt: now });
    },
    withTrialSettleLock: async <T>(_userId: string, task: () => Promise<T>) => await task(),
    settleSubscriptionPlan: async (originalTransactionId: string, planId: string) => {
      const row = pendingTrials.find((item) => item.originalTransactionId === originalTransactionId);
      if (!row || row.planId !== "trial_pending") return false;
      row.planId = planId;
      return true;
    },
    pendingTrialSubscriptions: async () => pendingTrials.filter((row) => row.planId === "trial_pending"
      || (row.planId === "go" && claims.get(row.userId)?.deviceMarkedAt && !claims.get(row.userId)?.grantedAt)),
  }),
}));

const emptyClaim = { startedAt: null, originalTransactionId: null, deviceMarkAttemptedAt: null, deviceMarkedAt: null, grantedAt: null };
type PendingTrial = { originalTransactionId: string; userId: string; planId: string; freeTrial: boolean; status: string; productId: string; environment: string; expiresAt: Date | null };
const pendingTrials: PendingTrial[] = [];
const entitlementsApplied: string[] = [];
let failEntitlement = false;
mock.module("../services/billing/apple/applyEntitlement", () => ({
  applyPersonalPlanEntitlement: async (userId: string) => {
    if (failEntitlement) throw new Error("entitlement store down");
    entitlementsApplied.push(userId);
  },
}));
mock.module("../services/billing/apple/service", () => ({
  retryAppleNotifications: async () => ({ notifications: { failed: 0 }, lapsedFailures: 0 }),
}));

let deviceBits: { bit0: boolean; bit1: boolean } | "never_set" | "down" = "never_set";
const deviceCheckRequests: { url: string; body: Record<string, unknown>; authorization: string }[] = [];
globalThis.fetch = (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
  const url = String(input instanceof Request ? input.url : input);
  if (!url.includes("devicecheck.apple.com")) throw new Error(`unexpected fetch ${url}`);
  deviceCheckRequests.push({ url, body: JSON.parse(String(init?.body)), authorization: String(new Headers(init?.headers).get("authorization")) });
  if (deviceBits === "down") return new Response("unavailable", { status: 503 });
  if (url.endsWith("/update_two_bits")) return new Response("", { status: 200 });
  return deviceBits === "never_set" ? new Response("Failed to find bit state", { status: 200 }) : Response.json(deviceBits);
}) as typeof fetch;

const pkcs8 = (key: KeyObject) => key.export({ format: "pem", type: "pkcs8" }).toString();
const iapKeys = ec();
const deviceCheckKeys = ec();
const CONFIGURED_ENV = {
  APPLE_IAP_KEY_ID: "IAPKEY1234",
  APPLE_IAP_ISSUER_ID: "11111111-2222-3333-4444-555555555555",
  APPLE_IAP_PRIVATE_KEY: pkcs8(iapKeys.privateKey),
  DEVICECHECK_KEY_ID: "DCKEY12345",
  DEVICECHECK_PRIVATE_KEY: pkcs8(deviceCheckKeys.privateKey),
  // The fixtures use development App Attest keys, which need this opt-in.
  APPLE_TRIAL_ALLOW_DEVELOPMENT: "1",
  CRON_SECRET: "cron-secret",
};

const challengeRoute = await import("../app/api/billing/apple/trial/challenge/route");
const verifyRoute = await import("../app/api/billing/apple/trial/verify/route");
const cronRoute = await import("../app/api/cron/apple-notifications/route");

const headers = {
  authorization: "Bearer access-token",
  "x-stack-refresh-token": "refresh-token",
  "x-cmux-bundle-id": "com.cmux.app",
  "content-type": "application/json",
};

async function newChallenge(): Promise<string> {
  const response = await challengeRoute.POST(new Request("https://cmux.test/api/billing/apple/trial/challenge", { method: "POST", headers, body: "{}" }));
  expect(response.status).toBe(200);
  return (await response.json() as { challenge: string }).challenge;
}

async function verify(body: Record<string, unknown>) {
  const response = await verifyRoute.POST(new Request("https://cmux.test/api/billing/apple/trial/verify", {
    method: "POST", headers, body: JSON.stringify({ deviceCheckToken: "ZGV2aWNl", productId: PRODUCT_ID, appTransactionId: "2000000123456789", ...body }),
  }));
  return { status: response.status, body: await response.json() as Record<string, unknown> };
}

beforeEach(() => {
  currentUser = { id: "user-a", isAnonymous: false, primaryEmail: "a@example.com", primaryEmailVerified: true };
  Object.assign(process.env, CONFIGURED_ENV);
  delete process.env.VERCEL_ENV;
  challenges.clear();
  keys.clear();
  claims.clear();
  accountOffered = true;
  deviceBits = "never_set";
  deviceCheckRequests.length = 0;
  pendingTrials.length = 0;
  entitlementsApplied.length = 0;
  failEntitlement = false;
});

describe("POST /api/billing/apple/trial/verify", () => {
  test("a genuine attestation on a fresh device is eligible and gets a signed introductory-offer JWS", async () => {
    const device = ec();
    const challenge = await newChallenge();
    const result = await verify({ ...attestation(device, challenge), challenge, assertion: null });
    expect(result).toMatchObject({ status: 200, body: { eligible: true, reason: null, legacyTrialAllowed: true } });
    const [header, payload] = String(result.body.introductoryOfferJWS).split(".").slice(0, 2)
      .map((part) => JSON.parse(Buffer.from(part, "base64url").toString()) as Record<string, unknown>);
    expect(header).toMatchObject({ alg: "ES256", kid: "IAPKEY1234" });
    expect(payload).toMatchObject({
      bid: "com.cmux.app", productId: PRODUCT_ID, allowIntroductoryOffer: true,
      transactionId: "2000000123456789", aud: "introductory-offer-eligibility",
    });
    // A development key queries the development DeviceCheck host with an ES256 team token.
    expect(deviceCheckRequests[0]?.url).toBe("https://api.development.devicecheck.apple.com/v1/query_two_bits");
    expect(JSON.parse(Buffer.from(deviceCheckRequests[0]!.authorization.split(".")[1]!, "base64url").toString())).toMatchObject({ iss: "7WLXT3NR37" });
    expect(claims.get("user-a")).toMatchObject({ status: "verified", deviceCheckToken: "ZGV2aWNl" });
  });

  test("a challenge works once, only for the account it was issued to", async () => {
    const device = ec();
    const challenge = await newChallenge();
    const proof = attestation(device, challenge);
    expect((await verify({ ...proof, challenge, assertion: null })).body.eligible).toBe(true);
    expect((await verify({ ...proof, challenge, assertion: null })).body.reason).toBe("challenge_invalid");
    const other = await newChallenge();
    currentUser = { ...currentUser, id: "user-b" };
    expect((await verify({ ...attestation(ec(), other), challenge: other, assertion: null })).body.reason).toBe("challenge_invalid");
  });

  test("later checks use assertions; an unknown key asks for re-attestation and a replayed counter fails", async () => {
    const device = ec();
    const first = await newChallenge();
    const proof = attestation(device, first);
    await verify({ ...proof, challenge: first, assertion: null });
    claims.clear();
    const second = await newChallenge();
    expect((await verify({ keyId: proof.keyId, attestation: null, assertion: assertion(device, second, 1), challenge: second })).body.eligible).toBe(true);
    const third = await newChallenge();
    expect((await verify({ keyId: proof.keyId, attestation: null, assertion: assertion(device, third, 1), challenge: third })).body.reason).toBe("attest_failed");
    const fourth = await newChallenge();
    const unknown = await verify({ keyId: Buffer.alloc(32, 7).toString("base64"), attestation: null, assertion: assertion(device, fourth, 2), challenge: fourth });
    expect(unknown).toEqual({ status: 409, body: { error: "attest_key_unknown" } });
  });

  test("forged or foreign proofs are refused", async () => {
    const challenge = await newChallenge();
    expect((await verify({ ...attestation(ec(), challenge, "7WLXT3NR37.dev.cmux.app.beta"), challenge, assertion: null })).body.reason).toBe("attest_failed");
    const other = await newChallenge();
    const proof = attestation(ec(), "a different challenge");
    expect((await verify({ ...proof, challenge: other, assertion: null })).body.reason).toBe("attest_failed");
    // A development key is refused in production.
    process.env.VERCEL_ENV = "production";
    const prod = await newChallenge();
    expect((await verify({ ...attestation(ec(), prod), challenge: prod, assertion: null })).body.reason).toBe("attest_failed");
  });

  test("one trial per iPhone and per account, and one key per account", async () => {
    deviceBits = { bit0: true, bit1: false };
    let challenge = await newChallenge();
    expect((await verify({ ...attestation(ec(), challenge), challenge, assertion: null })).body.reason).toBe("device_already_trialed");
    deviceBits = "never_set";
    claims.set("user-a", { ...emptyClaim, userId: "user-a", keyId: "k", deviceCheckToken: null, status: "started", startedAt: new Date() });
    challenge = await newChallenge();
    expect((await verify({ ...attestation(ec(), challenge), challenge, assertion: null })).body.reason).toBe("account_already_trialed");
    claims.clear();
    const shared = ec();
    challenge = await newChallenge();
    const proof = attestation(shared, challenge);
    await verify({ ...proof, challenge, assertion: null });
    currentUser = { ...currentUser, id: "user-b" };
    challenge = await newChallenge();
    expect((await verify({ keyId: proof.keyId, attestation: null, assertion: assertion(shared, challenge, 1), challenge })).body.reason).toBe("device_key_in_use");
  });

  test("fails closed when the account is not offered a trial or the trial is not configured", async () => {
    accountOffered = false;
    let challenge = await newChallenge();
    expect((await verify({ ...attestation(ec(), challenge), challenge, assertion: null })).body.reason).toBe("not_offered");
    accountOffered = true;
    delete process.env.DEVICECHECK_PRIVATE_KEY;
    challenge = await newChallenge();
    expect((await verify({ ...attestation(ec(), challenge), challenge, assertion: null })).body).toEqual({
      eligible: false, introductoryOfferJWS: null, reason: "trial_unavailable", legacyTrialAllowed: false,
    });
    expect((await verify({ ...attestation(ec(), challenge), challenge, assertion: null, productId: "com.cmux.app.pro.monthly" })).status).toBe(400);
  });
});

describe("trial device settlement (apple-notifications cron)", () => {
  async function startedTrial(userId: string, originalTransactionId: string) {
    currentUser = { ...currentUser, id: userId };
    const device = ec();
    const challenge = await newChallenge();
    const proof = attestation(device, challenge);
    expect((await verify({ ...proof, challenge, assertion: null })).body.eligible).toBe(true);
    // What the subscription write does in its transaction for a fresh verified claim.
    claims.set(userId, { ...claims.get(userId)!, status: "started", startedAt: new Date(), originalTransactionId });
    pendingTrials.push({ originalTransactionId, userId, planId: "trial_pending", freeTrial: true, status: "active", productId: PRODUCT_ID, environment: "Production", expiresAt: null });
  }
  const runCron = async () => {
    const response = await cronRoute.GET(new Request("https://cmux.test/api/cron/apple-notifications", { headers: { authorization: "Bearer cron-secret" } }));
    return (await response.json() as { trials: Record<string, number> }).trials;
  };

  test("grants the trial only after the device's bit0 is set, and refuses a reused iPhone", async () => {
    await startedTrial("user-a", "otid-a");
    expect(await runCron()).toMatchObject({ granted: 1 });
    expect(pendingTrials[0]!.planId).toBe("go");
    expect(deviceCheckRequests.map((request) => request.url.split("/").at(-1))).toEqual(["query_two_bits", "query_two_bits", "update_two_bits"]);
    expect(entitlementsApplied).toEqual(["user-a"]);

    // Another account on the same iPhone, verified before the first trial started: bit0 is set now.
    await startedTrial("user-b", "otid-b");
    deviceBits = { bit0: true, bit1: false };
    expect(await runCron()).toMatchObject({ device_reused: 1 });
    expect(pendingTrials[1]!.planId).toBe("trial_unverified");
    expect(claims.get("user-b")?.status).toBe("device_reused");
  });

  test("a grant interrupted after the plan flipped is finished by the next run", async () => {
    await startedTrial("user-a", "otid-a");
    failEntitlement = true;
    expect(await runCron()).toMatchObject({ granted: 1 });
    expect(pendingTrials[0]!.planId).toBe("go");
    expect(claims.get("user-a")?.grantedAt).toBeNull();
    failEntitlement = false;
    expect(await runCron()).toMatchObject({ granted: 1 });
    expect(entitlementsApplied).toEqual(["user-a"]);
    expect(claims.get("user-a")?.grantedAt).toBeInstanceOf(Date);
    expect(await runCron()).toMatchObject({ granted: 0 });
  });

  test("fails closed and retries while DeviceCheck is down", async () => {
    await startedTrial("user-a", "otid-a");
    deviceBits = "down";
    expect(await runCron()).toMatchObject({ pending: 1 });
    expect(pendingTrials[0]!.planId).toBe("trial_pending");
    expect(entitlementsApplied).toEqual([]);
    deviceBits = "never_set";
    expect(await runCron()).toMatchObject({ granted: 1 });
    expect(pendingTrials[0]!.planId).toBe("go");
  });
});

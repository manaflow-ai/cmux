import { expect, test } from "bun:test";
import { TeamBroker } from "../src/broker";
import { challengeSigningInput, encodeBase64URL, requestSigningInput } from "../src/crypto";
import type { DeviceRecord } from "../src/contracts/common";
import type { TeamStore } from "../src/storage/team-store";

const now = 1_789_000_000;
const authority = {
  environment: "test",
  projectId: "project",
  teamId: "team",
  userId: "user",
  verifiedAt: now,
};

test("the owning Mac can recover a forgotten registration with fresh Stack auth", async () => {
  const keyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const rawPublic = await crypto.subtle.exportKey("raw", keyPair.publicKey);
  const endpointID = Array.from(new Uint8Array(rawPublic), byte => byte.toString(16).padStart(2, "0")).join("");
  const descriptor = {
    identity: { ...authority, deviceId: "mac", appNamespace: "cmux", buildTag: "test" },
    endpointId: endpointID,
    identityGeneration: 1,
    metadata: { platform: "mac" as const, displayName: "Mac", appVersion: "1", pairingEnabled: true, capabilities: [], relayURLs: [] },
  };
  let device: DeviceRecord = { descriptor, deviceRecordId: endpointID, revision: 2, revoked: true };
  let pendingChallenge: { challengeId: string; nonce: string; payloadHash: string; expiresAt: number } | undefined;
  const store = {
    getDevice: () => device,
    getDeviceByRecordId: () => device,
    consumeDeviceProof: () => { throw new Error("revoked devices must use recovery enrollment"); },
    issueChallenge: (_identity: unknown, value: { challengeId: string; nonceHash: string; payloadHash: string; expiresAt: number }) => {
      pendingChallenge = { challengeId: value.challengeId, nonce: "recovery-nonce", payloadHash: value.payloadHash, expiresAt: value.expiresAt };
    },
    findRegistrationReceipt: () => null,
    validateRegistrationChallenge: () => {},
    commitRegistration: (input: { descriptor: typeof descriptor }) => {
      device = { ...device, descriptor: input.descriptor, revision: 3, revoked: false };
      return { device, idempotent: false };
    },
    readRevision: () => device.revision,
    observeAuthority: () => device.revision,
  } as unknown as TeamStore;
  const broker = new TeamBroker({
    store,
    now: () => now,
    charge: async () => {},
    ownership: { reserve: async () => {} },
    relays: { configuration: { relayURLs: [] } } as never,
    issueTicket: async () => ({ token: "fresh-ticket", expiresAt: now + 3600, refreshAfter: now + 3300 }),
    verifyStack: async () => authority,
    canManageTeam: async () => false,
    verifyTeamMember: async () => true,
  });
  const requestID = "recover-open";
  const plainSetup = { schemaId: "session.open.v1" as const, requestId: requestID, device: descriptor };
  const nonce = encodeBase64URL(crypto.getRandomValues(new Uint8Array(16)));
  const issuedAt = now;
  const signed = await crypto.subtle.sign(
    "Ed25519",
    keyPair.privateKey,
    new TextEncoder().encode(requestSigningInput(descriptor, requestID, issuedAt, plainSetup, nonce)),
  );
  const setup = {
    ...plainSetup,
    proof: { requestId: requestID, nonce, issuedAt, signature: encodeBase64URL(new Uint8Array(signed)) },
  };
  const opened = await broker.open(setup, authority, now + 3600, true);
  expect(opened.response.schemaId).toBe("session.ready.v1");
  expect("device" in opened.response).toBe(false);
  expect("challenge" in opened.response).toBe(true);
  expect(pendingChallenge).toBeDefined();

  const challenge = pendingChallenge!;
  const enrollmentBytes = new TextEncoder().encode(challengeSigningInput(descriptor, challenge.challengeId, challenge.nonce));
  const enrollmentSignature = await crypto.subtle.sign("Ed25519", keyPair.privateKey, enrollmentBytes);
  const registered = await broker.execute(opened.session!, {
    schemaId: "device.register.v1",
    requestId: "recover-register",
    device: descriptor,
    challengeId: challenge.challengeId,
    nonce: challenge.nonce,
    signature: encodeBase64URL(new Uint8Array(enrollmentSignature)),
  });
  expect(registered.response.schemaId).toBe("device.registered.v1");
  expect(device.revoked).toBe(false);

  await expect(broker.open(setup, authority, now + 3600, false)).rejects.toMatchObject({ code: "device_revoked" });
});

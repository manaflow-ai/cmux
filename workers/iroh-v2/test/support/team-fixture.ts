import type { VerifiedAuthority } from "../../src/auth";
import { TeamBroker, type BrokerSession } from "../../src/broker";
import type { DeviceDescriptor, Identity } from "../../src/contracts/common";
import { challengeSigningInput, encodeBase64URL, issueTicket, requestSigningInput } from "../../src/crypto";
import { RelayIssuer } from "../../src/relay";
import { TeamStore } from "../../src/storage/team-store";
import { sqliteStorage } from "./sqlite-storage";

export const ENVIRONMENT = "staging";
export const PROJECT_ID = "project";
export const RELAY_URL = "https://relay.example/";
export const TICKET_KEY_ID = "k1";
export const TICKET_KEY = encodeBase64URL(new Uint8Array(32).fill(7));

/** A deterministic Ed25519 device key: same seed, same EndpointID and signatures. */
export interface DeviceKey { endpointId: string; privateKey: CryptoKey }

export async function deviceKey(seed: number): Promise<DeviceKey> {
  const pkcs8 = new Uint8Array([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20, ...new Uint8Array(32).fill(seed)]);
  const privateKey = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, true, ["sign"]);
  const jwk = await crypto.subtle.exportKey("jwk", privateKey) as JsonWebKey;
  const raw = Uint8Array.from(atob(jwk.x!.replaceAll("-", "+").replaceAll("_", "/") + "="), char => char.charCodeAt(0));
  return { endpointId: Array.from(raw, byte => byte.toString(16).padStart(2, "0")).join(""), privateKey };
}

export async function sign(key: DeviceKey, value: string): Promise<string> {
  return encodeBase64URL(new Uint8Array(await crypto.subtle.sign("Ed25519", key.privateKey, new TextEncoder().encode(value))));
}

export async function relayPem(seed: number): Promise<string> {
  const pkcs8 = new Uint8Array([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20, ...new Uint8Array(32).fill(seed)]);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
}

/**
 * Replaces crypto.randomUUID and crypto.getRandomValues with counters so
 * record ids, session ids and challenge nonces are byte-for-byte repeatable.
 * Returns a restore function.
 */
export function deterministicRandom(): () => void {
  const originalUUID = crypto.randomUUID.bind(crypto);
  const originalRandom = crypto.getRandomValues.bind(crypto);
  let uuid = 0, random = 0;
  crypto.randomUUID = () => `00000000-0000-4000-8000-${(++uuid).toString(16).padStart(12, "0")}` as `${string}-${string}-${string}-${string}-${string}`;
  crypto.getRandomValues = (<T extends ArrayBufferView | null>(array: T): T => {
    if (array) {
      const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
      random++;
      for (let index = 0; index < bytes.length; index++) bytes[index] = (random * 31 + index) & 0xff;
    }
    return array;
  }) as typeof crypto.getRandomValues;
  return () => { crypto.randomUUID = originalUUID; crypto.getRandomValues = originalRandom; };
}

export function identity(teamId: string, userId: string, deviceId: string, overrides: Partial<Identity> = {}): Identity {
  return { environment: ENVIRONMENT, projectId: PROJECT_ID, teamId, userId, deviceId, appNamespace: "com.cmux.app", buildTag: "release", ...overrides };
}

export function descriptor(key: DeviceKey, id: Identity, platform: "mac" | "ios", capabilities: string[], pairingEnabled = true): DeviceDescriptor {
  return {
    identity: id, endpointId: key.endpointId, identityGeneration: 1,
    metadata: { platform, displayName: `${platform} ${id.deviceId}`, appVersion: "1.0", pairingEnabled, capabilities, relayURLs: [RELAY_URL] },
  };
}

/** One team: real TeamStore over SQLite, real ticket and relay signing, fixed clock. */
export async function teamHarness(teamId: string, now: () => number) {
  const store = new TeamStore(sqliteStorage(), { environment: ENVIRONMENT, projectId: PROJECT_ID, teamId });
  store.initialize(1);
  const relays = new RelayIssuer({
    environment: ENVIRONMENT, projectId: PROJECT_ID, issuer: "cmux", audience: "cmux-relay", keyId: "relay-1",
    privateKeyPem: await relayPem(3), relayURLs: [RELAY_URL],
  });
  const broker = new TeamBroker({
    store, ownership: { reserve: async () => {} }, relays, now,
    charge: async () => {},
    issueTicket: (device, at) => issueTicket(device, TICKET_KEY_ID, TICKET_KEY, at),
    verifyStack: async (_token, id, at) => ({ environment: id.environment, projectId: id.projectId, teamId: id.teamId, userId: id.userId, verifiedAt: at }),
    canManageTeam: async () => false,
    verifyTeamMember: async () => true,
  });
  /** Seeds an enrolled device the way the production register path commits it. */
  function enroll(device: DeviceDescriptor, at: number) {
    store.issueChallenge(device.identity, { challengeId: `challenge-${device.identity.deviceId}`, nonceHash: "nonce-hash", payloadHash: "payload-hash", issuedAt: at, expiresAt: at + 1800 });
    return store.commitRegistration({
      descriptor: device, challengeId: `challenge-${device.identity.deviceId}`, nonceHash: "nonce-hash", payloadHash: "payload-hash",
      requestId: `register-${device.identity.deviceId}`, requestHash: `hash-${device.identity.deviceId}`, now: at,
    }).device;
  }
  function authority(id: Identity, verifiedAt: number): VerifiedAuthority {
    return { environment: id.environment, projectId: id.projectId, teamId: id.teamId, userId: id.userId, verifiedAt };
  }
  function session(device: DeviceDescriptor, verifiedAt: number, issue = false): BrokerSession {
    return {
      sessionId: `session-${device.identity.deviceId}`, identity: device.identity, endpointId: device.endpointId,
      identityGeneration: device.identityGeneration, authority: authority(device.identity, verifiedAt), expiresAt: verifiedAt + 3600, issueTicket: issue,
    };
  }
  async function openSetup(key: DeviceKey, device: DeviceDescriptor, requestId: string, issuedAt: number) {
    const plain = { schemaId: "session.open.v1" as const, requestId, device };
    const nonce = "AAAAAAAAAAAAAAAAAAAAAA";
    return { ...plain, proof: { requestId, nonce, issuedAt, signature: await sign(key, requestSigningInput(device, requestId, issuedAt, plain, nonce)) } };
  }
  async function registerSignature(key: DeviceKey, device: DeviceDescriptor, challengeId: string, nonce: string) {
    return sign(key, challengeSigningInput(device, challengeId, nonce));
  }
  return { store, broker, relays, enroll, authority, session, openSetup, registerSignature };
}

import { expect, test } from "bun:test";
import { canonicalJSON, challengeSigningInput, encodeBase64URL, identityKey, issueTicket, verifyDeviceSignature, verifyTicket } from "../src/crypto";
import { descriptor } from "./fixtures";

const secret = encodeBase64URL(crypto.getRandomValues(new Uint8Array(32)));
test("ticket renewal overlaps without invalidating an unexpired token", async () => {
  const old = await issueTicket(descriptor, "key-1", secret, 1000);
  const replacement = await issueTicket(descriptor, "key-1", secret, 4300);
  for (const ticket of [old, replacement]) {
    expect((await verifyTicket(ticket.token, { "key-1": secret }, "staging", "project", 4301)).identity).toEqual(descriptor.identity);
  }
  await expect(verifyTicket(old.token, { "key-1": secret }, "staging", "project", 4600)).rejects.toThrow("ticket_expired");
});
test("rejects tampering, wrong environment/project and unknown signing keys", async () => {
  const ticket = await issueTicket(descriptor, "key-1", secret, 1000);
  await expect(verifyTicket(ticket.token, { "key-1": secret }, "production", "project", 1001)).rejects.toThrow("environment_mismatch");
  await expect(verifyTicket(ticket.token, { "key-1": secret }, "staging", "other", 1001)).rejects.toThrow("environment_mismatch");
  await expect(verifyTicket(ticket.token, {}, "staging", "project", 1001)).rejects.toThrow("unauthorized");
  const parts = ticket.token.split(".");
  parts[0] = encodeBase64URL(new TextEncoder().encode("{}"));
  await expect(verifyTicket(parts.join("."), { "key-1": secret }, "staging", "project", 1001)).rejects.toThrow("unauthorized");
});
test("device proof binds the challenge, endpoint and complete scope", async () => {
  const keys = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  if (!("publicKey" in keys)) throw new Error("Expected an Ed25519 key pair");
  const exported = await crypto.subtle.exportKey("raw", keys.publicKey);
  if (!(exported instanceof ArrayBuffer)) throw new Error("Expected raw public key bytes");
  const raw = new Uint8Array(exported);
  const endpointId = Array.from(raw, (b) => b.toString(16).padStart(2, "0")).join("");
  const device = { ...descriptor, endpointId };
  const input = challengeSigningInput(device, "challenge", "nonce");
  const sig = encodeBase64URL(new Uint8Array(await crypto.subtle.sign("Ed25519", keys.privateKey, new TextEncoder().encode(input))));
  await verifyDeviceSignature(endpointId, input, sig);
  await expect(verifyDeviceSignature(endpointId, challengeSigningInput(device, "other", "nonce"), sig)).rejects.toThrow("invalid_device_proof");
  expect(await identityKey(device)).not.toBe(await identityKey({ ...device, identity: { ...device.identity, buildTag: "other" } }));
});
test("canonical wire values are ordered and never silently lose data", () => {
  expect(canonicalJSON({ z: 1, a: { b: true } })).toBe('{"a":{"b":true},"z":1}');
  for (const value of [undefined, 1.5, NaN, Infinity, { missing: undefined }]) expect(() => canonicalJSON(value)).toThrow("invalid_request");
});

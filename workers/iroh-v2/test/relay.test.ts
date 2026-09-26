import { expect, test } from "bun:test";
import { RELAY_TOKEN_AUDIENCE, RELAY_TOKEN_ISSUER, RelayIssuer } from "../src/relay";
import { decodeBase64URL } from "../src/crypto";
import { descriptor } from "./fixtures";

test("relay credentials use an offline-verifiable 30-minute grant and stable user scope", async () => {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  if (!("privateKey" in pair)) throw new Error("Expected key pair");
  const exported = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  if (!(exported instanceof ArrayBuffer)) throw new Error("Expected private key bytes");
  const pem = "-----BEGIN PRIVATE KEY-----\n" + btoa(Array.from(new Uint8Array(exported), byte => String.fromCharCode(byte)).join("")) + "\n-----END PRIVATE KEY-----\n";
  const issuer = new RelayIssuer({
    environment: "staging", projectId: "project", issuer: RELAY_TOKEN_ISSUER, audience: RELAY_TOKEN_AUDIENCE,
    keyId: "key1", privateKeyPem: pem, relayURLs: ["https://relay.example/"],
  });
  const first = (await issuer.issue(descriptor, 1000))[0]!;
  const second = (await issuer.issue({ ...descriptor, identity: { ...descriptor.identity, teamId: "other-team", deviceId: "other-device" } }, 2500))[0]!;
  expect(first.expiresAt).toBe(2800);
  expect(first.refreshAfter).toBe(2500);
  const parse = (token: string) => {
    const [header, body, signature] = token.split(".") as [string, string, string];
    return { header, body, signature, claims: JSON.parse(new TextDecoder().decode(decodeBase64URL(body))) };
  };
  const a = parse(first.token), b = parse(second.token);
  expect(a.claims.sub).toBe(b.claims.sub);
  expect(a.claims.iss).toBe("cmux");
  expect(a.claims.aud).toBe("cmux-relay");
  expect(a.claims.endpoint_id).toBe(descriptor.endpointId);
  expect(a.claims.exp - a.claims.iat).toBe(1800);
  expect(await crypto.subtle.verify("Ed25519", pair.publicKey, decodeBase64URL(a.signature), new TextEncoder().encode(a.header + "." + a.body))).toBe(true);
  await expect(issuer.issue(descriptor, 1000, ["https://unconfigured.example/"])).rejects.toThrow("invalid_request");
});

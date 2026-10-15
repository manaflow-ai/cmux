// App Attest verification for the iOS trial check: proves a request comes
// from a genuine copy of the cmux app (com.cmux.app, team 7WLXT3NR37) on a
// genuine Apple device. Follows Apple's "Validating apps that connect to your
// server": an attestation once per key, then an assertion per request.
// https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server

import { createHash, createPublicKey, verify as verifySignature, X509Certificate, type KeyObject } from "node:crypto";

/** Apple App Attestation Root CA, pinned. Valid until 2045-03-15. */
export const APPLE_APP_ATTESTATION_ROOT_CA = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

export class AppAttestError extends Error {
  constructor(readonly reason: string) {
    super(`App Attest verification failed: ${reason}`);
    this.name = "AppAttestError";
  }
}

// Minimal CBOR decoder: the subset App Attest uses (unsigned and negative
// integers, byte and text strings, arrays, maps, simple values).

type Cbor = number | bigint | string | Buffer | boolean | null | undefined | Cbor[] | Map<Cbor, Cbor>;

const MAX_CBOR_ITEMS = 16;

function decodeCbor(input: Buffer): Cbor {
  let offset = 0;
  const need = (count: number) => {
    if (offset + count > input.length) throw new AppAttestError("cbor_truncated");
  };
  const length = (info: number): number => {
    if (info < 24) return info;
    const size = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : info === 27 ? 8 : 0;
    if (size === 0) throw new AppAttestError("cbor_unsupported_length");
    need(size);
    const value = size === 8 ? Number(input.readBigUInt64BE(offset)) : input.readUIntBE(offset, size);
    offset += size;
    if (!Number.isSafeInteger(value)) throw new AppAttestError("cbor_length_too_large");
    return value;
  };
  const item = (depth: number): Cbor => {
    if (depth > 16) throw new AppAttestError("cbor_too_deep");
    need(1);
    const initial = input[offset++]!;
    const major = initial >> 5;
    const info = initial & 0x1f;
    switch (major) {
      case 0:
        return length(info);
      case 1:
        return -1 - length(info);
      case 2:
      case 3: {
        const size = length(info);
        need(size);
        const bytes = input.subarray(offset, offset + size);
        offset += size;
        return major === 2 ? Buffer.from(bytes) : bytes.toString("utf8");
      }
      case 4: {
        const size = length(info);
        // App Attest arrays and maps are tiny; a huge declared length is hostile input.
        if (size > MAX_CBOR_ITEMS) throw new AppAttestError("cbor_too_many_items");
        return Array.from({ length: size }, () => item(depth + 1));
      }
      case 5: {
        const size = length(info);
        if (size > MAX_CBOR_ITEMS) throw new AppAttestError("cbor_too_many_items");
        const map = new Map<Cbor, Cbor>();
        for (let index = 0; index < size; index += 1) map.set(item(depth + 1), item(depth + 1));
        return map;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        if (info === 23) return undefined;
        throw new AppAttestError("cbor_unsupported_simple");
      default:
        throw new AppAttestError("cbor_unsupported_type");
    }
  };
  const value = item(0);
  if (offset !== input.length) throw new AppAttestError("cbor_trailing_bytes");
  return value;
}

function mapField(value: Cbor, key: string): Cbor {
  if (!(value instanceof Map)) throw new AppAttestError("cbor_not_a_map");
  return value.get(key);
}

function bytesField(value: Cbor, key: string): Buffer {
  const field = mapField(value, key);
  if (!Buffer.isBuffer(field)) throw new AppAttestError(`missing_${key}`);
  return field;
}

const sha256 = (...parts: Buffer[]) => createHash("sha256").update(Buffer.concat(parts)).digest();

type AuthenticatorData = {
  readonly rpIdHash: Buffer;
  readonly counter: number;
  readonly aaguid: Buffer | null;
  readonly credentialId: Buffer | null;
};

function parseAuthenticatorData(data: Buffer, withCredential: boolean): AuthenticatorData {
  if (data.length < 37) throw new AppAttestError("auth_data_short");
  const rpIdHash = data.subarray(0, 32);
  const counter = data.readUInt32BE(33);
  if (!withCredential) return { rpIdHash, counter, aaguid: null, credentialId: null };
  if (data.length < 55) throw new AppAttestError("auth_data_short");
  const aaguid = data.subarray(37, 53);
  const idLength = data.readUInt16BE(53);
  if (data.length < 55 + idLength) throw new AppAttestError("auth_data_short");
  return { rpIdHash, counter, aaguid, credentialId: data.subarray(55, 55 + idLength) };
}

/** The App ID App Attest binds to: `<team id>.<bundle id>`. */
export type AppAttestApp = { readonly teamId: string; readonly bundleId: string };

const PRODUCTION_AAGUID = Buffer.concat([Buffer.from("appattest"), Buffer.alloc(7)]);
const DEVELOPMENT_AAGUID = Buffer.from("appattestdevelop");

/** DER of OID 1.2.840.113635.100.8.2, the App Attest nonce extension. */
const NONCE_EXTENSION_OID = Buffer.from([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02]);

/** The 32-byte nonce in the leaf's extension: OCTET STRING { SEQUENCE { [1] { OCTET STRING nonce } } }. */
function certificateNonce(certificate: X509Certificate): Buffer {
  const der = certificate.raw;
  const at = der.indexOf(NONCE_EXTENSION_OID);
  if (at < 0) throw new AppAttestError("nonce_extension_missing");
  const window = der.subarray(at + NONCE_EXTENSION_OID.length, at + NONCE_EXTENSION_OID.length + 16);
  const marker = window.indexOf(Buffer.from([0xa1, 0x22, 0x04, 0x20]));
  if (marker < 0) throw new AppAttestError("nonce_extension_malformed");
  const start = at + NONCE_EXTENSION_OID.length + marker + 4;
  return der.subarray(start, start + 32);
}

/** The uncompressed EC point (0x04 || X || Y) of a P-256 key. */
function uncompressedPoint(key: KeyObject): Buffer {
  const jwk = key.export({ format: "jwk" });
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || !jwk.x || !jwk.y) throw new AppAttestError("unexpected_key_type");
  return Buffer.concat([Buffer.from([0x04]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]);
}

export type VerifiedAttestation = {
  /** SPKI DER, base64. Stored to verify later assertions. */
  readonly publicKeySpki: string;
  readonly environment: "production" | "development";
  readonly signCount: number;
};

export type AttestationInput = {
  readonly attestation: Buffer;
  /** The key identifier the app reports (base64 of SHA-256 of the public key). */
  readonly keyId: Buffer;
  readonly clientDataHash: Buffer;
  readonly app: AppAttestApp;
  readonly allowDevelopment: boolean;
  readonly now: Date;
  /** Pinned root; tests inject a local chain. */
  readonly rootCertificatePem?: string;
};

function verifyChain(x5c: Cbor, rootPem: string, now: Date): X509Certificate {
  if (!Array.isArray(x5c) || x5c.length < 2 || !x5c.every(Buffer.isBuffer)) throw new AppAttestError("x5c_missing");
  const [leaf, intermediate] = (x5c as Buffer[]).map((der) => new X509Certificate(der));
  const root = new X509Certificate(rootPem);
  const inValidity = (certificate: X509Certificate) =>
    new Date(certificate.validFrom) <= now && now <= new Date(certificate.validTo);
  if (!leaf!.verify(intermediate!.publicKey) || !leaf!.checkIssued(intermediate!)) throw new AppAttestError("leaf_not_signed_by_intermediate");
  if (!intermediate!.verify(root.publicKey) || !intermediate!.checkIssued(root)) throw new AppAttestError("intermediate_not_signed_by_root");
  if (![leaf!, intermediate!, root].every(inValidity)) throw new AppAttestError("certificate_expired");
  return leaf!;
}

/** Verifies a first-use attestation and returns the key to store. Throws AppAttestError. */
export function verifyAttestation(input: AttestationInput): VerifiedAttestation {
  const object = decodeCbor(input.attestation);
  if (mapField(object, "fmt") !== "apple-appattest") throw new AppAttestError("unexpected_format");
  const statement = mapField(object, "attStmt");
  const authData = bytesField(object, "authData");
  const leaf = verifyChain(mapField(statement, "x5c"), input.rootCertificatePem ?? APPLE_APP_ATTESTATION_ROOT_CA, input.now);
  if (!certificateNonce(leaf).equals(sha256(authData, input.clientDataHash))) throw new AppAttestError("nonce_mismatch");
  const point = uncompressedPoint(leaf.publicKey);
  if (!sha256(point).equals(input.keyId)) throw new AppAttestError("key_id_mismatch");
  const parsed = parseAuthenticatorData(authData, true);
  if (!parsed.rpIdHash.equals(sha256(Buffer.from(`${input.app.teamId}.${input.app.bundleId}`)))) throw new AppAttestError("app_id_mismatch");
  if (parsed.counter !== 0) throw new AppAttestError("counter_not_zero");
  let environment: VerifiedAttestation["environment"];
  if (parsed.aaguid!.equals(PRODUCTION_AAGUID)) environment = "production";
  else if (parsed.aaguid!.equals(DEVELOPMENT_AAGUID) && input.allowDevelopment) environment = "development";
  else throw new AppAttestError("environment_not_allowed");
  if (!parsed.credentialId!.equals(input.keyId)) throw new AppAttestError("credential_id_mismatch");
  return {
    publicKeySpki: leaf.publicKey.export({ format: "der", type: "spki" }).toString("base64"),
    environment,
    signCount: 0,
  };
}

export type AssertionInput = {
  readonly assertion: Buffer;
  readonly clientDataHash: Buffer;
  readonly publicKeySpki: string;
  readonly previousSignCount: number;
  readonly app: AppAttestApp;
};

/** Verifies a later assertion and returns the new sign count to store. Throws AppAttestError. */
export function verifyAssertion(input: AssertionInput): number {
  const object = decodeCbor(input.assertion);
  const signature = bytesField(object, "signature");
  const authenticatorData = bytesField(object, "authenticatorData");
  const key = createPublicKey({ key: Buffer.from(input.publicKeySpki, "base64"), format: "der", type: "spki" });
  const nonce = sha256(authenticatorData, input.clientDataHash);
  if (!verifySignature("sha256", nonce, key, signature)) throw new AppAttestError("bad_signature");
  const parsed = parseAuthenticatorData(authenticatorData, false);
  if (!parsed.rpIdHash.equals(sha256(Buffer.from(`${input.app.teamId}.${input.app.bundleId}`)))) throw new AppAttestError("app_id_mismatch");
  if (parsed.counter <= input.previousSignCount) throw new AppAttestError("counter_not_increasing");
  return parsed.counter;
}

/** `SHA256(utf8(challenge) || utf8(productId))`, the client data both sides hash. */
export function trialClientDataHash(challenge: string, productId: string): Buffer {
  return sha256(Buffer.from(challenge, "utf8"), Buffer.from(productId, "utf8"));
}

/**
 * Install-key signatures as a device makes them (mesh M2, cx-0op.4). The
 * message is built here by hand, independent of src/mesh/signed-request.ts, so
 * a change to the wire format breaks these tests:
 *
 *   cmux-mesh-v1 \n purpose \n target \n wgPublicKey \n installPublicKey \n name \n signedAt \n nonce
 *
 * ECDSA P-256 with SHA-256; the public key is the 65-byte uncompressed point
 * and the signature the 64-byte r||s, both base64.
 */

export interface InstallKey {
  readonly publicKey: string;
  readonly privateKey: CryptoKey;
}

const b64 = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes));
const b64url = (bytes: Uint8Array): string => b64(bytes).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");

export async function makeInstallKey(): Promise<InstallKey> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  if (!("publicKey" in pair)) throw new Error("ECDSA generateKey returned no key pair");
  const raw = await crypto.subtle.exportKey("raw", pair.publicKey);
  if (!(raw instanceof ArrayBuffer)) throw new Error("raw export returned no bytes");
  return { publicKey: b64(new Uint8Array(raw)), privateKey: pair.privateKey };
}

export interface SignOptions {
  readonly signedAt?: number;
  readonly nonce?: string;
  /** Sign with this key while claiming `install.publicKey` (a forged request). */
  readonly signWith?: InstallKey;
}

/** Every purpose a device signs: enroll and rotate-key (M2), its own peer map and tunnel config (M3), and its public IPv6 address. */
export type SignedPurpose = "enroll" | "rotate-key" | "peers" | "tunnel" | "address";

export function signedMessage(fields: {
  readonly purpose: SignedPurpose;
  readonly target: string;
  readonly wgPublicKey: string;
  readonly installPublicKey: string;
  readonly name: string;
  readonly signedAt: number;
  readonly nonce: string;
}): string {
  return ["cmux-mesh-v1", fields.purpose, fields.target, fields.wgPublicKey, fields.installPublicKey, fields.name, String(fields.signedAt), fields.nonce].join("\n");
}

async function sign(install: InstallKey, message: string): Promise<string> {
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, install.privateKey, new TextEncoder().encode(message));
  return b64(new Uint8Array(signature));
}

const freshNonce = () => b64url(crypto.getRandomValues(new Uint8Array(16)));

/** The body of an enroll request (`POST /v1/meshes/{meshId}/devices`, or with `code` the device-enrollments route). */
export async function enrollBody(
  install: InstallKey,
  meshId: string,
  body: { readonly name: string; readonly wgPublicKey: string; readonly code?: string },
  options: SignOptions = {},
) {
  const signedAt = options.signedAt ?? Date.now();
  const nonce = options.nonce ?? freshNonce();
  const message = signedMessage({
    purpose: "enroll",
    target: meshId,
    wgPublicKey: body.wgPublicKey,
    installPublicKey: install.publicKey,
    name: body.name,
    signedAt,
    nonce,
  });
  return { ...body, installPublicKey: install.publicKey, signedAt, nonce, signature: await sign(options.signWith ?? install, message) };
}

/** The body of `POST /v1/devices/{deviceId}/rotate-key`. */
export async function rotateBody(install: InstallKey, deviceId: string, newPublicKey: string, options: SignOptions = {}) {
  const signedAt = options.signedAt ?? Date.now();
  const nonce = options.nonce ?? freshNonce();
  const message = signedMessage({ purpose: "rotate-key", target: deviceId, wgPublicKey: newPublicKey, installPublicKey: install.publicKey, name: "", signedAt, nonce });
  return { newPublicKey, signedAt, nonce, signature: await sign(options.signWith ?? install, message) };
}

/**
 * The body of a device-signed read (mesh M3): `POST /v1/devices/{deviceId}/signed/peers`
 * or `/signed/tunnel`. The message has an empty WireGuard key and name; the
 * install public key is the device's own (the server fills it from the device
 * record), so it is not in the body.
 */
export async function deviceRequestBody(install: InstallKey, deviceId: string, purpose: "peers" | "tunnel", options: SignOptions = {}) {
  const signedAt = options.signedAt ?? Date.now();
  const nonce = options.nonce ?? freshNonce();
  const message = signedMessage({ purpose, target: deviceId, wgPublicKey: "", installPublicKey: install.publicKey, name: "", signedAt, nonce });
  return { signedAt, nonce, signature: await sign(options.signWith ?? install, message) };
}

/**
 * The body of `POST /v1/devices/{deviceId}/signed/address`: the device's
 * current public IPv6 address (null clears it). The address is the message's
 * name line (empty when cleared), so the signature covers it.
 */
export async function addressBody(install: InstallKey, deviceId: string, publicIpv6: string | null, options: SignOptions = {}) {
  const signedAt = options.signedAt ?? Date.now();
  const nonce = options.nonce ?? freshNonce();
  const message = signedMessage({ purpose: "address", target: deviceId, wgPublicKey: "", installPublicKey: install.publicKey, name: publicIpv6 ?? "", signedAt, nonce });
  return { publicIpv6, signedAt, nonce, signature: await sign(options.signWith ?? install, message) };
}

/** SHA-256 hex, as the Worker stores an enrollment code. */
export async function sha256Hex(text: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

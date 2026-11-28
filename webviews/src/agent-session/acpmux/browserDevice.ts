// Browser bootstrap only. Native bridge and development hosts never enter this path.
// Credentials live for this page, not in URLs, host config, storage or the ACP inspector.
import type { RawRequest } from "./protocol/client";

export type BrowserDeviceEnrollment = { accessToken: string; publicKey: string };
export type BrowserDeviceIdentity = {
  origin: string;
  cacheKey: string;
  enrollment?: BrowserDeviceEnrollment;
  credential?: string;
  /** The device key (RFD 0083): a non-extractable ECDSA P-256 key the hub bound the credential to. */
  signingKey?: CryptoKey;
  enrolling?: Promise<string>;
};

let identity: BrowserDeviceIdentity | undefined;
let generation = 0;

export function browserDeviceError(reason = "device.identity_required"): Error & { reason: string } {
  return Object.assign(new Error(reason), { reason });
}

/** Called by browser sign-in before the host connects. Replacing it also invalidates in-flight joins. */
export function setBrowserDeviceEnrollment(enrollment: BrowserDeviceEnrollment): void {
  clearBrowserDeviceIdentity();
  if (!enrollment.accessToken.trim() || !enrollment.publicKey.trim()) throw browserDeviceError();
  identity = {
    origin: window.location.origin,
    cacheKey: `browser-device-${++generation}`,
    enrollment: { ...enrollment },
  };
}

/** Sign-out, denial and revocation require a new explicit sign-in; reconnect never silently enrolls again. */
export function clearBrowserDeviceIdentity(): void {
  if (identity) {
    identity.enrollment = undefined;
    identity.credential = undefined;
    identity.signingKey = undefined;
    identity.enrolling = undefined;
  }
  identity = undefined;
}

/** Check before opening the socket, so even its listener token cannot leave this origin. */
export function prepareBrowserDevice(endpoint: URL): BrowserDeviceIdentity {
  const page = new URL(window.location.href);
  const protocol = page.protocol === "https:" ? "wss:" : page.protocol === "http:" ? "ws:" : undefined;
  if (
    !protocol ||
    endpoint.protocol !== protocol ||
    endpoint.host !== page.host ||
    endpoint.username ||
    endpoint.password ||
    endpoint.search ||
    endpoint.hash
  )
    throw browserDeviceError("device.origin_mismatch");
  if (!identity || identity.origin !== page.origin) throw browserDeviceError();
  return identity;
}

export function browserDeviceIsCurrent(device: BrowserDeviceIdentity): boolean {
  return identity === device;
}

export function invalidateBrowserDevice(device: BrowserDeviceIdentity | undefined): void {
  if (device && device === identity) clearBrowserDeviceIdentity();
}

// A sign-in cannot wait forever on the ordinary RPC progress threshold.
async function deviceRequest(request: RawRequest, method: string, params: Record<string, unknown>): Promise<any> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      request(method, params),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(browserDeviceError("device.handshake_timeout")), 30_000);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

const base64url = (bytes: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

/**
 * The device key the hub binds the credential to (RFD 0083, "Known gap: the device credential is a bearer"): ECDSA
 * P-256, the one signing algorithm every WebCrypto has had for years. The private half is non-extractable and lives
 * only with this page's identity, like the credential; the hub gets the raw public point.
 */
async function deviceKeyPair(): Promise<{ key: CryptoKey; deviceKey: string } | undefined> {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) return undefined;
  const pair = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]);
  return { key: pair.privateKey, deviceKey: base64url(await subtle.exportKey("raw", pair.publicKey)) };
}

/** Proves the key for this connection: signs the hub's nonce and the daemon's binding for it. */
async function deviceProof(request: RawRequest, credential: string, key: CryptoKey) {
  const challenge = (await deviceRequest(request, "_acpmux/device_challenge", { credential })) as {
    machineId?: unknown;
    nonce?: unknown;
    binding?: unknown;
  };
  const { machineId, nonce, binding } = challenge ?? {};
  if (typeof machineId !== "string" || typeof nonce !== "string" || typeof binding !== "string")
    throw browserDeviceError("device.unauthorized");
  const message = new TextEncoder().encode(`cmux-device-hello/v1\n${machineId}\n${nonce}\n${binding}`);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, message);
  return { credential, nonce, signature: base64url(signature) };
}

/** Enrollment and hello use the actual client's socket; every fresh socket presents hello anew. */
export async function connectBrowserDevice(device: BrowserDeviceIdentity, request: RawRequest): Promise<void> {
  const current = () => {
    if (!browserDeviceIsCurrent(device)) throw browserDeviceError();
  };
  current();
  try {
    if (!device.credential) {
      if (!device.enrolling) {
        const enrollment = device.enrollment;
        if (!enrollment) throw browserDeviceError();
        device.enrollment = undefined;
        device.enrolling = (async () => {
          const pair = await deviceKeyPair();
          const params = pair ? { ...enrollment, deviceKey: pair.deviceKey } : enrollment;
          const result = (await deviceRequest(request, "_acpmux/device_enroll", params)) as {
            credential?: unknown;
          };
          current();
          if (typeof result?.credential !== "string" || !result.credential.startsWith("cmm_"))
            throw browserDeviceError("device.enroll_refused");
          device.credential = result.credential;
          device.signingKey = pair?.key;
          return result.credential;
        })();
      }
      await device.enrolling;
    }
    current();
    const credential = device.credential!;
    // A daemon from before the proof has no challenge; it also enrolled without the key, so the bearer hello stands.
    const hello = device.signingKey
      ? await deviceProof(request, credential, device.signingKey).catch((error) => {
          if ((error as { code?: unknown } | null)?.code === -32601) return { credential };
          throw error;
        })
      : { credential };
    current();
    const result = (await deviceRequest(request, "_acpmux/device_hello", hello)) as {
      auth?: unknown;
    };
    current();
    if (result?.auth !== "webDevice") throw browserDeviceError("device.unauthorized");
  } catch (error) {
    // Once enrolled, an ordinary disconnect retains the identity for the next socket. A
    // refused identity does not; an uncertain enrollment must not mint devices on a retry loop.
    const reason = (error as { reason?: unknown } | null)?.reason;
    const code = (error as { code?: unknown } | null)?.code;
    if (
      !device.credential ||
      typeof code === "number" ||
      (typeof reason === "string" && reason.startsWith("device.") && reason !== "device.handshake_timeout")
    )
      invalidateBrowserDevice(device);
    throw error;
  }
}

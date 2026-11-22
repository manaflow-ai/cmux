// Browser bootstrap only. Native bridge and development hosts never enter this path.
// Credentials live for this page, not in URLs, host config, storage or the ACP inspector.
import type { RawRequest } from "./protocol/client";

export type BrowserDeviceEnrollment = { accessToken: string; publicKey: string };
export type BrowserDeviceIdentity = {
  origin: string;
  cacheKey: string;
  enrollment?: BrowserDeviceEnrollment;
  credential?: string;
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
          const result = (await deviceRequest(request, "_acpmux/device_enroll", enrollment)) as {
            credential?: unknown;
          };
          current();
          if (typeof result?.credential !== "string" || !result.credential.startsWith("cmm_"))
            throw browserDeviceError("device.enroll_refused");
          device.credential = result.credential;
          return result.credential;
        })();
      }
      await device.enrolling;
    }
    current();
    const result = (await deviceRequest(request, "_acpmux/device_hello", { credential: device.credential })) as {
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

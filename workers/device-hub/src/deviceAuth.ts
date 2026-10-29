import { canonicalRequest, verifyDeviceSignature } from "./crypto";
import { ApiError } from "./errors";

export const TS_WINDOW_S = 60;
export const REPLAY_WINDOW_MS = 120_000;
export const DEVICE_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export interface DeviceHeaders {
  id: string;
  ts: string;
  sig: string;
}

/** Reads X-Device-Id / -Ts / -Sig and checks the timestamp window. */
export function readDeviceHeaders(headers: Headers, nowMs: number): DeviceHeaders {
  const id = headers.get("x-device-id") ?? "";
  const ts = headers.get("x-device-ts") ?? "";
  const sig = headers.get("x-device-sig") ?? "";
  if (!DEVICE_ID.test(id) || !/^\d{1,12}$/.test(ts) || !sig) {
    throw new ApiError(401, "bad_signature", "missing or malformed device headers");
  }
  if (Math.abs(Number(ts) - nowMs / 1000) > TS_WINDOW_S) {
    throw new ApiError(401, "stale_timestamp", "X-Device-Ts is not within 60 s of server time");
  }
  return { id, ts, sig };
}

/**
 * Verifies the device signature over the canonical request string and returns
 * that string. Callers key replay checks on the low-S form of the signature
 * (`lowSHex`): (r, s) and (r, n - s) both verify, and Secure Enclave keys do
 * not produce low-S signatures, so rejecting high-S is not an option. Keying on
 * the message alone would refuse two identical requests in the same second.
 */
export async function checkDeviceSignature(signingKey: string, method: string, url: URL, body: Uint8Array, h: DeviceHeaders): Promise<string> {
  const message = await canonicalRequest(method, url.pathname + url.search, h.ts, body);
  if (!(await verifyDeviceSignature(signingKey, h.sig, message))) {
    throw new ApiError(401, "bad_signature", "device signature does not verify");
  }
  return message;
}

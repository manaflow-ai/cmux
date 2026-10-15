// Apple DeviceCheck two-bit state: per-device bits that survive reinstalls,
// app deletion and new Apple IDs. bit0 = this iPhone already started a cmux
// trial. https://developer.apple.com/documentation/devicecheck/accessing-and-modifying-per-device-data

import { randomUUID } from "node:crypto";
import { importPKCS8, SignJWT } from "jose";

import { APPLE_TEAM_ID } from "./trialConfig";

type Env = Record<string, string | undefined>;

export type DeviceCheckBits = { readonly bit0: boolean; readonly bit1: boolean };

export type DeviceCheckClient = {
  /** Null bits when the device never had a bit set. Throws on a transport or auth failure. */
  readonly queryBits: (deviceToken: string) => Promise<DeviceCheckBits>;
  readonly updateBits: (deviceToken: string, bits: Partial<DeviceCheckBits>) => Promise<void>;
};

export class DeviceCheckError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
    this.name = "DeviceCheckError";
  }
}

export type DeviceCheckCredentials = { readonly keyId: string; readonly privateKey: string };

/** The DeviceCheck key (a separate .p8 with the DeviceCheck capability), or null when not configured. */
export function deviceCheckCredentials(env: Env = process.env): DeviceCheckCredentials | null {
  const keyId = env.DEVICECHECK_KEY_ID?.trim();
  const privateKey = env.DEVICECHECK_PRIVATE_KEY?.trim()?.replaceAll("\\n", "\n");
  return keyId && privateKey ? { keyId, privateKey } : null;
}

export function deviceCheckClient(
  credentials: DeviceCheckCredentials,
  options: { readonly development: boolean; readonly fetch?: typeof fetch; readonly now?: () => Date },
): DeviceCheckClient {
  const host = options.development ? "https://api.development.devicecheck.apple.com" : "https://api.devicecheck.apple.com";
  const fetchImpl = options.fetch ?? fetch;
  const now = options.now ?? (() => new Date());
  const token = async () => new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: credentials.keyId })
    .setIssuer(APPLE_TEAM_ID)
    .setIssuedAt(Math.floor(now().getTime() / 1000))
    .sign(await importPKCS8(credentials.privateKey, "ES256"));
  const post = async (path: string, body: Record<string, unknown>) => {
    const response = await fetchImpl(`${host}${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${await token()}`, "content-type": "application/json" },
      body: JSON.stringify({ ...body, transaction_id: randomUUID(), timestamp: now().getTime() }),
      signal: AbortSignal.timeout(5_000),
    });
    const text = await response.text();
    if (!response.ok) throw new DeviceCheckError(response.status, `DeviceCheck ${path} failed with ${response.status}: ${text.slice(0, 200)}`);
    return text;
  };
  return {
    queryBits: async (deviceToken) => {
      const text = await post("/v1/query_two_bits", { device_token: deviceToken });
      // A device whose bits were never set answers 200 with plain text.
      if (!text.trim().startsWith("{")) return { bit0: false, bit1: false };
      const body = JSON.parse(text) as { bit0?: boolean; bit1?: boolean };
      return { bit0: body.bit0 === true, bit1: body.bit1 === true };
    },
    updateBits: async (deviceToken, bits) => {
      await post("/v1/update_two_bits", { device_token: deviceToken, ...bits });
    },
  };
}

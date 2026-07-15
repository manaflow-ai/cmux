import { createHash, createHmac } from "node:crypto";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  IrohConfigurationError,
  type IrohInvalidInputError,
  IrohRelayMintError,
} from "./errors";
import { IrohTrustBrokerConfig } from "./config";
import {
  IROH_RELAY_MINTER_PATH,
  parseIrohMinterUrl,
  type IrohMinterUrlPolicy,
} from "./minterUrlPolicy";
import { IROH_RELAY_TOKEN_LIFETIME_SECONDS, endpointId } from "./model";

const MAX_MINTER_RESPONSE_BYTES = 32 * 1_024;
export { IROH_RELAY_MINTER_PATH };

export type IrohRelayMintResult = {
  readonly token: string;
  readonly expiresAt: Date;
};

export type IrohRelayMinterShape = {
  readonly mint: (input: {
    readonly endpointId: string;
    readonly lifetimeSeconds: typeof IROH_RELAY_TOKEN_LIFETIME_SECONDS;
    readonly now: Date;
  }) => Effect.Effect<
    IrohRelayMintResult,
    IrohConfigurationError | IrohInvalidInputError | IrohRelayMintError
  >;
};

export class IrohRelayMinter extends Context.Tag("cmux/IrohRelayMinter")<
  IrohRelayMinter,
  IrohRelayMinterShape
>() {}

export const IrohRelayMinterLive = Layer.effect(
  IrohRelayMinter,
  Effect.gen(function* () {
    const config = yield* IrohTrustBrokerConfig;
    return {
      mint: (input) => mintWithIsolatedService(config, input),
    } satisfies IrohRelayMinterShape;
  }),
);

function mintWithIsolatedService(
  config: typeof IrohTrustBrokerConfig.Service,
  input: Parameters<IrohRelayMinterShape["mint"]>[0],
): Effect.Effect<
  IrohRelayMintResult,
  IrohConfigurationError | IrohInvalidInputError | IrohRelayMintError
> {
  return Effect.tryPromise({
    try: async () => {
      endpointId(input.endpointId);
      const url = parseMinterUrl(config.relayMinterUrl, {
        allowInsecureLoopback: config.relayMinterInsecureLoopbackOptIn,
        deploymentEnvironment: config.deploymentEnvironment,
        isVercelDeployment: config.isVercelDeployment,
      });
      const secret = parseMinterHmacSecret(config.relayMinterHmacSecretBase64);
      const body = JSON.stringify({
        endpointId: input.endpointId,
        lifetimeSeconds: IROH_RELAY_TOKEN_LIFETIME_SECONDS,
      });
      const timestamp = String(Math.floor(input.now.getTime() / 1_000));
      const bodyHash = createHash("sha256").update(body).digest("hex");
      const signature = createHmac("sha256", secret)
        .update(`POST\n${url.pathname}\n${timestamp}\n${bodyHash}`, "utf8")
        .digest("base64url");
      const response = await fetch(url, {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.timeout(10_000),
        headers: {
          "content-type": "application/json",
          "x-cmux-iroh-timestamp": timestamp,
          "x-cmux-iroh-signature": signature,
        },
        body,
      });
      if (!response.ok) throw new IrohRelayMintError({ code: "minter_rejected" });
      const raw = await readBoundedMinterJson(response);
      if (
        typeof raw.token !== "string" ||
        raw.token.length < 16 ||
        raw.token.length > 16_384 ||
        !/^[a-z2-7]+$/.test(raw.token)
      ) {
        throw new IrohRelayMintError({ code: "invalid_minter_response" });
      }
      if (typeof raw.expiresAt !== "string") throw new IrohRelayMintError({ code: "invalid_minter_response" });
      const expiresAt = new Date(raw.expiresAt);
      const contractExpiry = input.now.getTime() + IROH_RELAY_TOKEN_LIFETIME_SECONDS * 1_000;
      if (
        !Number.isFinite(expiresAt.getTime()) ||
        expiresAt <= input.now ||
        expiresAt.getTime() > contractExpiry + 60_000 ||
        expiresAt.getTime() < contractExpiry - 5 * 60_000
      ) {
        throw new IrohRelayMintError({ code: "invalid_minter_expiry" });
      }
      return { token: raw.token, expiresAt };
    },
    catch: (cause) => {
      if ((cause as { _tag?: unknown } | null)?._tag === "IrohConfigurationError") {
        return cause as IrohConfigurationError;
      }
      if ((cause as { _tag?: unknown } | null)?._tag === "IrohInvalidInputError") {
        return cause as IrohInvalidInputError;
      }
      if ((cause as { _tag?: unknown } | null)?._tag === "IrohRelayMintError") {
        return cause as IrohRelayMintError;
      }
      return new IrohRelayMintError({ code: "minter_unavailable", cause: safeCause(cause) });
    },
  });
}

export async function readBoundedMinterJson(
  response: Response,
): Promise<{ token?: unknown; expiresAt?: unknown }> {
  if (
    response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() !==
    "application/json"
  ) {
    throw new IrohRelayMintError({ code: "invalid_minter_response" });
  }
  const contentLength = response.headers.get("content-length");
  if (contentLength) {
    const parsed = Number(contentLength);
    if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > MAX_MINTER_RESPONSE_BYTES) {
      throw new IrohRelayMintError({ code: "minter_response_too_large" });
    }
  }
  const reader = response.body?.getReader();
  if (!reader) throw new IrohRelayMintError({ code: "invalid_minter_response" });
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const next = await reader.read();
    if (next.done) break;
    total += next.value.byteLength;
    if (total > MAX_MINTER_RESPONSE_BYTES) {
      await reader.cancel();
      throw new IrohRelayMintError({ code: "minter_response_too_large" });
    }
    chunks.push(next.value);
  }
  const bytes = Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), total);
  let parsed: unknown;
  try {
    parsed = JSON.parse(bytes.toString("utf8"));
  } catch {
    throw new IrohRelayMintError({ code: "invalid_minter_response" });
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new IrohRelayMintError({ code: "invalid_minter_response" });
  }
  const object = parsed as Record<string, unknown>;
  const keys = Object.keys(object);
  if (keys.length !== 2 || !keys.includes("token") || !keys.includes("expiresAt")) {
    throw new IrohRelayMintError({ code: "invalid_minter_response" });
  }
  return object;
}

export function parseMinterUrl(
  value: string | undefined,
  policy: IrohMinterUrlPolicy = {
    allowInsecureLoopback: false,
    deploymentEnvironment: "production",
    isVercelDeployment: true,
  },
): URL {
  if (!value) throw new IrohConfigurationError({ component: "relay_minter" });
  try {
    return parseIrohMinterUrl(value, policy);
  } catch {
    throw new IrohConfigurationError({ component: "relay_minter" });
  }
}

export function parseMinterHmacSecret(value: string | undefined): Buffer {
  if (!value || value.length > 512) throw new IrohConfigurationError({ component: "relay_minter" });
  const decoded = Buffer.from(value, "base64");
  const canonicalPadded = decoded.toString("base64");
  const canonicalUnpadded = canonicalPadded.replace(/=+$/, "");
  if (
    decoded.byteLength < 32 ||
    decoded.byteLength > 256 ||
    (value !== canonicalPadded && value !== canonicalUnpadded)
  ) {
    throw new IrohConfigurationError({ component: "relay_minter" });
  }
  return decoded;
}

function safeCause(cause: unknown): unknown {
  return cause instanceof Error ? { name: cause.name } : { type: typeof cause };
}

import { readFile } from "node:fs/promises";
import { createPrivateKey, sign } from "node:crypto";

import { env } from "../../app/env";

const ASC_BASE_URL = "https://api.appstoreconnect.apple.com";
const ASC_JWT_AUDIENCE = "appstoreconnect-v1";
const ASC_JWT_TTL_SECONDS = 19 * 60;
const ASC_TIMEOUT_MS = 10_000;

export class AscApiError extends Error {
  readonly name = "AscApiError";

  constructor(
    message: string,
    readonly status: number,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

export class AscConfigurationError extends Error {
  readonly name = "AscConfigurationError";
}

export class AscNetworkError extends Error {
  readonly name = "AscNetworkError";

  constructor(message: string, readonly cause?: unknown) {
    super(message);
  }
}

export function isAscConfigured(): boolean {
  return Boolean(
    env.ASC_KEY_ID &&
      env.ASC_ISSUER_ID &&
      (env.ASC_PRIVATE_KEY || env.ASC_PRIVATE_KEY_PATH),
  );
}

export async function ascFetch<T = unknown>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  if (!isAscConfigured()) {
    throw new AscConfigurationError("App Store Connect is not configured");
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), ASC_TIMEOUT_MS);
  try {
    const response = await fetch(`${ASC_BASE_URL}${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        accept: "application/json",
        "content-type": "application/json",
        ...init.headers,
        authorization: `Bearer ${await ascJwt()}`,
      },
    });

    if (!response.ok) {
      const details = await responseJson(response);
      throw new AscApiError(
        `App Store Connect request failed with ${response.status}`,
        response.status,
        details,
      );
    }

    if (response.status === 204) return null as T;
    return (await responseJson(response)) as T;
  } catch (error) {
    if (error instanceof AscApiError || error instanceof AscConfigurationError) {
      throw error;
    }
    if (error instanceof Error && error.name === "AbortError") {
      throw new AscNetworkError("App Store Connect request timed out", error);
    }
    throw new AscNetworkError("App Store Connect request failed", error);
  } finally {
    clearTimeout(timeout);
  }
}

async function ascJwt(): Promise<string> {
  if (!env.ASC_KEY_ID || !env.ASC_ISSUER_ID) {
    throw new AscConfigurationError("App Store Connect credentials are incomplete");
  }

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: env.ASC_KEY_ID, typ: "JWT" };
  const payload = {
    iss: env.ASC_ISSUER_ID,
    iat: now,
    exp: now + ASC_JWT_TTL_SECONDS,
    aud: ASC_JWT_AUDIENCE,
  };
  const input = `${base64UrlJson(header)}.${base64UrlJson(payload)}`;
  const key = createPrivateKey(await ascPrivateKey());
  const derSignature = sign("sha256", Buffer.from(input), key);
  return `${input}.${base64Url(derToJoseSignature(derSignature, 32))}`;
}

async function ascPrivateKey(): Promise<string> {
  if (env.ASC_PRIVATE_KEY) {
    return env.ASC_PRIVATE_KEY.replaceAll("\\n", "\n");
  }
  if (env.ASC_PRIVATE_KEY_PATH) {
    return readFile(env.ASC_PRIVATE_KEY_PATH, "utf8");
  }
  throw new AscConfigurationError("App Store Connect private key is missing");
}

async function responseJson(response: Response): Promise<unknown> {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return { body: text };
  }
}

function base64UrlJson(value: unknown): string {
  return base64Url(Buffer.from(JSON.stringify(value)));
}

function base64Url(value: Buffer): string {
  return value
    .toString("base64")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function derToJoseSignature(signature: Buffer, partLength: number): Buffer {
  let offset = 0;
  if (signature[offset++] !== 0x30) throw new Error("Invalid ECDSA signature");
  offset = readDerLength(signature, offset).offset;
  if (signature[offset++] !== 0x02) throw new Error("Invalid ECDSA signature");
  const rLength = readDerLength(signature, offset);
  offset = rLength.offset;
  const r = signature.subarray(offset, offset + rLength.length);
  offset += rLength.length;
  if (signature[offset++] !== 0x02) throw new Error("Invalid ECDSA signature");
  const sLength = readDerLength(signature, offset);
  offset = sLength.offset;
  const s = signature.subarray(offset, offset + sLength.length);
  return Buffer.concat([leftPadUnsigned(r, partLength), leftPadUnsigned(s, partLength)]);
}

function readDerLength(
  buffer: Buffer,
  offset: number,
): { length: number; offset: number } {
  const first = buffer[offset++];
  if (first < 0x80) return { length: first, offset };
  const bytes = first & 0x7f;
  let length = 0;
  for (let index = 0; index < bytes; index++) {
    length = (length << 8) | buffer[offset++];
  }
  return { length, offset };
}

function leftPadUnsigned(value: Buffer, length: number): Buffer {
  const unsigned = value[0] === 0 ? value.subarray(1) : value;
  if (unsigned.length === length) return unsigned;
  if (unsigned.length > length) return unsigned.subarray(unsigned.length - length);
  return Buffer.concat([Buffer.alloc(length - unsigned.length), unsigned]);
}

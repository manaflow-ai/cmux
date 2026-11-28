import { createPublicKey, verify as verifySignature } from "node:crypto";

import { BROWSER_RELEASE_REPOSITORY_URL } from "./download";

/** Signed moving-channel feed published by the public binary repository. */
export const BROWSER_NIGHTLY_FEED_URL =
  `${BROWSER_RELEASE_REPOSITORY_URL}/releases/download/nightly/update.json`;

/** Immutable public R2 origin used by signed production feed entries. */
export const BROWSER_PUBLIC_ASSET_ORIGIN = "https://browser-assets.cmux.com";

/**
 * P-256 update public key compiled into cmux Browser's updater.
 *
 * This is public verification material, not a credential. Keep it byte-for-byte
 * in sync with cmux-browser's `docs/update-public-key.pem` whenever the updater
 * key is deliberately rotated.
 */
export const CMUX_BROWSER_UPDATE_PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzeE5/HttjLz27hU3LFU0h/88Ex7i
oqZjMnYz3AN/iyfNbz1meZL/8Kyd3PsvCvoiAI62dzAdAE+gNkbNrfw6/Q==
-----END PUBLIC KEY-----`;

const FEED_TIMEOUT_MS = 8_000;
const MAX_FEED_BYTES = 64 * 1024;
const MAX_PAYLOAD_BYTES = 60 * 1024;
const MAX_SIGNATURE_BYTES = 256;

interface BrowserNightlyTarget {
  readonly feedPlatform: string;
  readonly signedArchive: string;
  readonly artifacts: Readonly<Record<string, string>>;
}

/**
 * Explicit platform, architecture, and asset contract for public downloads.
 * A route outside this table never reaches GitHub. An asset inside the table is
 * offered only when the signed feed contains its platform archive and the
 * companion asset exists in the same verified release tag.
 */
const BROWSER_NIGHTLY_TARGETS = {
  "linux-x64": {
    feedPlatform: "linux-x64",
    signedArchive: "cmux-linux-x64.zip",
    artifacts: {
      run: "cmux-linux-x64-installer.run",
      deb: "cmux-linux-x64.deb",
      zip: "cmux-linux-x64.zip",
    },
  },
  "windows-x64": {
    feedPlatform: "windows-x64",
    signedArchive: "cmux-windows-x64.zip",
    artifacts: {
      installer: "cmux-windows-x64-installer.exe",
      zip: "cmux-windows-x64.zip",
    },
  },
  "mac-arm64": {
    feedPlatform: "mac-arm64",
    signedArchive: "cmux-macos-universal.zip",
    artifacts: {
      dmg: "cmux-macos-universal.dmg",
      zip: "cmux-macos-universal.zip",
    },
  },
  "mac-x64": {
    feedPlatform: "mac-x64",
    signedArchive: "cmux-macos-universal.zip",
    artifacts: {
      dmg: "cmux-macos-universal.dmg",
      zip: "cmux-macos-universal.zip",
    },
  },
} as const satisfies Record<string, BrowserNightlyTarget>;

export type BrowserNightlyDownloadErrorCode =
  | "not_found"
  | "unavailable"
  | "upstream_unavailable"
  | "invalid_feed";

export class BrowserNightlyDownloadError extends Error {
  constructor(readonly code: BrowserNightlyDownloadErrorCode) {
    super(code);
    this.name = "BrowserNightlyDownloadError";
  }
}

export interface BrowserNightlyDownloadDependencies {
  readonly fetch?: typeof globalThis.fetch;
  readonly publicKeyPem?: string;
}

export interface BrowserNightlyDownloadResolution {
  readonly url: string;
  readonly version: string;
}

interface SignedFeedPayload {
  readonly version: string;
  readonly platforms: Record<string, unknown>;
}

/** Resolves one stable website route to a verified public release asset. */
export async function resolveBrowserNightlyDownload(
  platform: string,
  artifact: string,
  dependencies: BrowserNightlyDownloadDependencies = {},
): Promise<BrowserNightlyDownloadResolution> {
  const target = routeTarget(platform, artifact);
  if (!target) throw new BrowserNightlyDownloadError("not_found");

  const fetchImplementation = dependencies.fetch ?? globalThis.fetch;
  const payload = await fetchAndVerifyFeed(
    fetchImplementation,
    dependencies.publicKeyPem ?? CMUX_BROWSER_UPDATE_PUBLIC_KEY_PEM,
  );
  const rawEntry = payload.platforms[target.config.feedPlatform];
  if (rawEntry === undefined) {
    throw new BrowserNightlyDownloadError("unavailable");
  }

  const assetLocation = verifiedAssetLocation(
    rawEntry,
    target.config.signedArchive,
    payload.version,
  );
  const url = assetLocation.kind === "r2"
    ? `${BROWSER_PUBLIC_ASSET_ORIGIN}/nightly/${encodeURIComponent(payload.version)}/${encodeURIComponent(target.assetName)}`
    : `${BROWSER_RELEASE_REPOSITORY_URL}/releases/download/${assetLocation.releaseTag}/${target.assetName}`;
  await requirePublishedAsset(fetchImplementation, url, assetLocation);

  return { url, version: payload.version };
}

async function fetchAndVerifyFeed(
  fetchImplementation: typeof globalThis.fetch,
  publicKeyPem: string,
): Promise<SignedFeedPayload> {
  let response: Response;
  try {
    response = await fetchImplementation(BROWSER_NIGHTLY_FEED_URL, {
      cache: "no-store",
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(FEED_TIMEOUT_MS),
    });
  } catch {
    throw new BrowserNightlyDownloadError("upstream_unavailable");
  }
  if (!response.ok) {
    throw new BrowserNightlyDownloadError("upstream_unavailable");
  }

  let envelopeText: string;
  try {
    envelopeText = await readBoundedUtf8(response, MAX_FEED_BYTES);
  } catch (error) {
    if (error instanceof BrowserNightlyDownloadError) throw error;
    throw new BrowserNightlyDownloadError("upstream_unavailable");
  }
  return verifyFeedEnvelope(envelopeText, publicKeyPem);
}

/** Verifies the exact signed bytes before parsing or trusting any payload URL. */
export function verifyFeedEnvelope(
  envelopeText: string,
  publicKeyPem = CMUX_BROWSER_UPDATE_PUBLIC_KEY_PEM,
): SignedFeedPayload {
  try {
    const envelope = JSON.parse(envelopeText) as unknown;
    if (!isRecord(envelope)) throw invalidFeed();
    const payloadBytes = decodeCanonicalBase64(
      envelope.payload,
      MAX_PAYLOAD_BYTES,
    );
    const signatureBytes = decodeCanonicalBase64(
      envelope.signature,
      MAX_SIGNATURE_BYTES,
    );
    const publicKey = createPublicKey(publicKeyPem);
    if (
      !verifySignature(
        "sha256",
        payloadBytes,
        publicKey,
        signatureBytes,
      )
    ) {
      throw invalidFeed();
    }

    const payloadText = new TextDecoder("utf-8", { fatal: true }).decode(
      payloadBytes,
    );
    const payload = JSON.parse(payloadText) as unknown;
    if (!isRecord(payload)) throw invalidFeed();
    if (payload.schema !== 1) throw invalidFeed();
    if (
      typeof payload.version !== "string" ||
      !/^\d{1,9}(?:\.\d{1,9}){3}$/u.test(payload.version)
    ) {
      throw invalidFeed();
    }
    if (!isRecord(payload.platforms)) throw invalidFeed();
    return {
      version: payload.version,
      platforms: payload.platforms,
    };
  } catch (error) {
    if (error instanceof BrowserNightlyDownloadError) throw error;
    throw invalidFeed();
  }
}

type VerifiedAssetLocation =
  | { readonly kind: "github"; readonly releaseTag: string }
  | {
      readonly kind: "r2";
      readonly sha256: string;
      readonly size: string;
    };

function verifiedAssetLocation(
  rawEntry: unknown,
  expectedArchive: string,
  version: string,
): VerifiedAssetLocation {
  if (!isRecord(rawEntry)) throw invalidFeed();
  if (
    typeof rawEntry.sha256 !== "string" ||
    !/^[a-f0-9]{64}$/u.test(rawEntry.sha256) ||
    typeof rawEntry.size !== "string" ||
    !/^[1-9]\d{0,15}$/u.test(rawEntry.size) ||
    !safeArchivePath(rawEntry.archive_root) ||
    !safeArchivePath(rawEntry.executable) ||
    typeof rawEntry.url !== "string"
  ) {
    throw invalidFeed();
  }

  let signedUrl: URL;
  try {
    signedUrl = new URL(rawEntry.url);
  } catch {
    throw invalidFeed();
  }
  if (
    signedUrl.protocol !== "https:" ||
    signedUrl.username !== "" ||
    signedUrl.password !== "" ||
    signedUrl.port !== "" ||
    signedUrl.search !== "" ||
    signedUrl.hash !== ""
  ) {
    throw invalidFeed();
  }

  if (signedUrl.host === "browser-assets.cmux.com") {
    const r2Path = signedUrl.pathname.match(
      /^\/nightly\/([^/]+)\/([^/]+)$/u,
    );
    if (!r2Path) throw invalidFeed();
    let r2Version: string;
    let r2Archive: string;
    try {
      r2Version = decodeURIComponent(r2Path[1]);
      r2Archive = decodeURIComponent(r2Path[2]);
    } catch {
      throw invalidFeed();
    }
    if (r2Version !== version || r2Archive !== expectedArchive) {
      throw invalidFeed();
    }
    return {
      kind: "r2",
      sha256: rawEntry.sha256,
      size: rawEntry.size,
    };
  }

  if (signedUrl.host !== "github.com") throw invalidFeed();

  const releasePath = signedUrl.pathname.match(
    /^\/manaflow-ai\/cmux-v2\/releases\/download\/([^/]+)\/([^/]+)$/u,
  );
  if (!releasePath || releasePath[2] !== expectedArchive) throw invalidFeed();
  const releaseTag = releasePath[1];
  if (releaseTag !== "nightly" && releaseTag !== `nightly-${version}`) {
    throw invalidFeed();
  }
  return { kind: "github", releaseTag };
}

async function requirePublishedAsset(
  fetchImplementation: typeof globalThis.fetch,
  url: string,
  location: VerifiedAssetLocation,
): Promise<void> {
  let response: Response;
  try {
    response = await fetchImplementation(url, {
      method: "HEAD",
      redirect: "manual",
      cache: "no-store",
      signal: AbortSignal.timeout(FEED_TIMEOUT_MS),
    });
  } catch {
    throw new BrowserNightlyDownloadError("upstream_unavailable");
  }

  if (response.status === 404 || response.status === 410) {
    throw new BrowserNightlyDownloadError("unavailable");
  }
  if (
    response.status !== 200 &&
    ![301, 302, 303, 307, 308].includes(response.status)
  ) {
    throw new BrowserNightlyDownloadError("upstream_unavailable");
  }
  if (location.kind === "r2" && response.status === 200) {
    if (
      response.headers.get("x-cmux-sha256") !== location.sha256 ||
      response.headers.get("x-cmux-size") !== location.size
    ) {
      throw new BrowserNightlyDownloadError("unavailable");
    }
  }
}

function routeTarget(
  platform: string,
  artifact: string,
): { config: BrowserNightlyTarget; assetName: string } | null {
  const targets = BROWSER_NIGHTLY_TARGETS as Readonly<
    Record<string, BrowserNightlyTarget>
  >;
  const config = targets[platform];
  const assetName = config?.artifacts[artifact];
  return config && assetName ? { config, assetName } : null;
}

async function readBoundedUtf8(
  response: Response,
  maximumBytes: number,
): Promise<string> {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^\d+$/u.test(contentLength) || Number(contentLength) > maximumBytes) {
      throw invalidFeed();
    }
  }
  if (!response.body) throw invalidFeed();

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel();
      throw invalidFeed();
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw invalidFeed();
  }
}

function decodeCanonicalBase64(
  value: unknown,
  maximumBytes: number,
): Buffer {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > Math.ceil(maximumBytes / 3) * 4 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(
      value,
    )
  ) {
    throw invalidFeed();
  }
  const decoded = Buffer.from(value, "base64");
  if (
    decoded.length === 0 ||
    decoded.length > maximumBytes ||
    decoded.toString("base64") !== value
  ) {
    throw invalidFeed();
  }
  return decoded;
}

function safeArchivePath(value: unknown): value is string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > 512 ||
    value.includes("\\") ||
    value.startsWith("/")
  ) {
    return false;
  }
  return value
    .split("/")
    .every((part) => part.length > 0 && part !== "." && part !== "..");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function invalidFeed(): BrowserNightlyDownloadError {
  return new BrowserNightlyDownloadError("invalid_feed");
}

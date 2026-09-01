import { createHash } from "node:crypto";

import {
  mobileMacCompatList,
  type MobileMacCompatEntry,
  type MobileMacCompatList,
} from "../../../data/mobile-mac-compat";

const CACHE_CONTROL = "public, s-maxage=300, stale-while-revalidate=86400";
const ALLOW_METHODS = "GET, OPTIONS";
const ALLOW_HEADERS = "If-None-Match, Content-Type";
/**
 * The app renders the download URLs as "where to download" pointers, so they
 * must stay on cmux-owned or cmux-release hosts.
 */
const ALLOWED_DOWNLOAD_URL_HOSTS = new Set([
  "cmux.com",
  "www.cmux.com",
  "github.com",
]);
const VERSION_PATTERN = /^\d+(\.\d+)*$/;
const BUILD_PATTERN = /^\d+$/;
const PAYLOAD = JSON.stringify(validateList(mobileMacCompatList));
const ETAG = `"${createHash("sha256").update(PAYLOAD).digest("base64url")}"`;

/**
 * Validates the reviewed list before it can be served: download URLs are
 * absolute https URLs on cmux-owned or cmux-release hosts, every version is
 * dotted numeric, nightly build counters are plain digits with no leading
 * zero, and entries are nonempty and strictly ascending by minIOSVersion so
 * the device's tier selection (greatest tier <= app version) is well
 * defined.
 */
export function validateList(input: MobileMacCompatList): MobileMacCompatList {
  downloadURL(input.downloads.stable, "downloads.stable");
  downloadURL(input.downloads.nightly, "downloads.nightly");

  if (input.entries.length === 0) {
    throw new Error("entries must list at least one tier");
  }
  let previous: MobileMacCompatEntry | undefined;
  for (const [index, entry] of input.entries.entries()) {
    const path = `entries[${index}]`;
    validateEntry(entry, path);
    // Tier selection on device assumes ordering, so duplicates or
    // out-of-order entries are an error.
    if (
      previous !== undefined &&
      compareDottedVersions(previous.minIOSVersion, entry.minIOSVersion) >= 0
    ) {
      throw new Error(
        `${path}.minIOSVersion ${entry.minIOSVersion} must be strictly greater than ${previous.minIOSVersion}`,
      );
    }
    previous = entry;
  }
  return input;
}

function validateEntry(entry: MobileMacCompatEntry, path: string): void {
  version(entry.minIOSVersion, `${path}.minIOSVersion`);
  if (entry.maxIOSVersion !== undefined) {
    version(entry.maxIOSVersion, `${path}.maxIOSVersion`);
    // An inverted range can never match any app version, so the tier would
    // be served, cached, and silently constrain nobody.
    if (compareDottedVersions(entry.minIOSVersion, entry.maxIOSVersion) > 0) {
      throw new Error(
        `${path} range is empty: minIOSVersion ${entry.minIOSVersion} exceeds maxIOSVersion ${entry.maxIOSVersion}`,
      );
    }
  }
  version(entry.stableMinVersion, `${path}.stableMinVersion`);
  if (entry.nightly !== undefined) {
    version(entry.nightly.minBaseVersion, `${path}.nightly.minBaseVersion`);
    build(entry.nightly.minBuild, `${path}.nightly.minBuild`);
  }
}

function version(input: string | undefined, path: string): void {
  const value = nonemptyString(input, path);
  if (!VERSION_PATTERN.test(value)) {
    throw new Error(`${path} must be a dotted numeric version, got ${value}`);
  }
}

function build(input: string | undefined, path: string): void {
  const value = nonemptyString(input, path);
  if (!BUILD_PATTERN.test(value)) {
    throw new Error(`${path} must be digits only, got ${value}`);
  }
  // Devices compare build counters as numeric strings (length first, then
  // lexicographic), so a zero-padded counter would break the comparison.
  if (value.length > 1 && value.startsWith("0")) {
    throw new Error(`${path} must not have a leading zero, got ${value}`);
  }
}

/**
 * Dotted-numeric compare with the device's semantics (missing components
 * count as zero): negative when a < b, zero when equal, positive when a > b.
 */
function compareDottedVersions(a: string, b: string): number {
  const left = a.split(".").map(Number);
  const right = b.split(".").map(Number);
  const count = Math.max(left.length, right.length);
  for (let index = 0; index < count; index += 1) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

function downloadURL(input: string | undefined, path: string): void {
  const value = nonemptyString(input, path);
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${path} must be an absolute URL`);
  }
  if (url.protocol !== "https:") {
    throw new Error(`${path} must use https`);
  }
  if (!ALLOWED_DOWNLOAD_URL_HOSTS.has(url.hostname.toLowerCase())) {
    throw new Error(
      `${path} must be on a cmux-owned or cmux-release host, got ${url.hostname}`,
    );
  }
}

function nonemptyString(input: string | undefined, path: string): string {
  if (typeof input !== "string" || input.trim().length === 0) {
    throw new Error(`${path} must be a nonempty string`);
  }
  // The served payload is the input verbatim, so committed values must
  // already be normalized: stray whitespace would otherwise pass validation
  // here and then silently break URL loads or version parsing on device.
  if (input !== input.trim()) {
    throw new Error(`${path} must not have leading or trailing whitespace`);
  }
  return input;
}

export async function GET(request: Request): Promise<Response> {
  if (matchesETag(request.headers.get("if-none-match"))) {
    return new Response(null, {
      status: 304,
      headers: commonHeaders(),
    });
  }

  return new Response(PAYLOAD, {
    status: 200,
    headers: {
      ...commonHeaders(),
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

export function OPTIONS(): Response {
  return new Response(null, {
    status: 204,
    headers: commonHeaders(),
  });
}

function commonHeaders(): Record<string, string> {
  return {
    "Cache-Control": CACHE_CONTROL,
    ETag: ETAG,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": ALLOW_METHODS,
    "Access-Control-Allow-Headers": ALLOW_HEADERS,
  };
}

function matchesETag(header: string | null): boolean {
  if (!header) return false;
  return header.split(",").some((value) => {
    const candidate = value.trim();
    return candidate === ETAG || candidate === "*";
  });
}

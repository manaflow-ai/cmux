import { createPublicKey, verify } from "node:crypto";
import { cacheLife } from "next/cache";
import { parseWhatsNewDocument, type WhatsNewDocument } from "./whats-new";

// Nightly digests (decision BOTTOM-LEFT-CARDS-AND-NIGHTLY-CHANGELOG K2): each
// cmux nightly publishes signed release notes next to its feed
// (`<notes base>/<build>.json` + `.sig`, Ed25519, the content-signing key the
// app trusts), and they embed the build's What's New digest under "whatsNew".
// The page and the feed read the same signed files; an unsigned or
// unreadable file is skipped.
export const nightlyNotesBase = "https://files-next.cmux.com/nightly-next/notes/";
export const contentSigningPublicKey = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4=";
const FETCH_TIMEOUT_MS = 8_000;
const NIGHTLY_LIMIT = 10;

/** Whether `signature` (base64) signs `data` with the raw Ed25519 key `publicKey` (base64). */
export function verifyContentSignature(data: Uint8Array, signature: string, publicKey = contentSigningPublicKey): boolean {
  try {
    const der = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(publicKey, "base64")]);
    const key = createPublicKey({ key: der, format: "der", type: "spki" });
    return verify(null, data, key, Buffer.from(signature.trim(), "base64"));
  } catch {
    return false;
  }
}

type Fetcher = (url: string) => Promise<Uint8Array | undefined>;

async function fetchBytes(url: string): Promise<Uint8Array | undefined> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
    return response.ok ? new Uint8Array(await response.arrayBuffer()) : undefined;
  } catch {
    return undefined;
  }
}

async function signed(name: string, fetcher: Fetcher, publicKey: string): Promise<unknown> {
  const [data, signature] = await Promise.all([fetcher(nightlyNotesBase + name), fetcher(`${nightlyNotesBase}${name}.sig`)]);
  if (!data || !signature || !verifyContentSignature(data, new TextDecoder().decode(signature), publicKey)) return undefined;
  try {
    return JSON.parse(new TextDecoder().decode(data));
  } catch {
    return undefined;
  }
}

/** The newest nightly digests that have entries, newest first (testable core). */
export async function loadNightlyDocuments(
  fetcher: Fetcher = fetchBytes,
  publicKey = contentSigningPublicKey,
  limit = NIGHTLY_LIMIT,
): Promise<WhatsNewDocument[]> {
  const index = (await signed("index.json", fetcher, publicKey)) as { builds?: { build: string }[] } | undefined;
  const builds = (index?.builds ?? []).filter((entry) => /^[0-9.]+$/.test(entry.build)).slice(0, limit);
  const notes = await Promise.all(builds.map((entry) => signed(`${entry.build}.json`, fetcher, publicKey)));
  const documents: WhatsNewDocument[] = [];
  for (const note of notes as ({ shortVersion?: string; whatsNew?: unknown } | undefined)[]) {
    if (!note?.whatsNew || typeof note.shortVersion !== "string") continue;
    const { document } = parseWhatsNewDocument(JSON.stringify(note.whatsNew), note.shortVersion);
    if (document && document.channel === "nightly" && document.entries.length > 0) documents.push(document);
  }
  return documents;
}

/** The nightly digests for the page and the feed, cached for an hour. */
export async function nightlyDocuments(): Promise<WhatsNewDocument[]> {
  "use cache";
  cacheLife("hours");
  return loadNightlyDocuments();
}

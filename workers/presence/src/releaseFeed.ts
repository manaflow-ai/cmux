// Release push: one public, unauthenticated fact per allowlisted update feed,
// "the newest build this feed serves", read from the feed's own public appcast.
//
// No client input is ever fetched: a feed id selects one of the hard-coded
// appcast URLs below, and an unknown id is a 404 at the route. The worker only
// re-reads what the public appcast already shows, so a poke needs no secret.
//
// This file holds no Cloudflare runtime import so bun can test it directly; the
// Durable Object in releaseFeedDo.ts wires these pieces to storage, alarms and
// hibernatable sockets.

/** Feed id -> the public Sparkle appcast it mirrors. */
export const RELEASE_FEEDS = {
  "nightly-next": "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml",
  tip: "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml",
  // The bare NIGHTLY-identity appcast (no /next/ segment) that cmux nightly
  // builds on the nightly-next channel read.
  "nightly-next-legacy": "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
} as const satisfies Record<string, string>;

export type ReleaseFeedId = keyof typeof RELEASE_FEEDS;

/** At most one appcast read per feed in this window; later pokes coalesce
 * into one deferred read at the window's end. */
export const POKE_COALESCE_MS = 10_000;
/** A read that has not answered in this time is dropped; the next poke or the
 * minute cron reads again. */
export const APPCAST_FETCH_TIMEOUT_MS = 8_000;
/** Today's feeds are about 5 KB; anything past this is not an appcast we publish. */
export const MAX_APPCAST_BYTES = 1_048_576;
/** Sockets one feed object holds before it answers 429 with Retry-After. */
export const MAX_RELEASE_SOCKETS = 10_000;

/** Parses a `feed` query value against the allowlist. */
export function parseReleaseFeedId(value: string | null): ReleaseFeedId | null {
  return value !== null && Object.hasOwn(RELEASE_FEEDS, value) ? (value as ReleaseFeedId) : null;
}

export interface ReleaseState {
  /** The newest item's sparkle:version. */
  build: number;
  /** That item's sparkle:shortVersionString (empty when the item has none). */
  version: string;
  /** When the worker first saw this build (ISO 8601, UTC). */
  at: string;
}

/** The one frame the socket sends, and the body `/latest` returns. */
export function releaseFrame(feed: ReleaseFeedId, state: ReleaseState): string {
  return JSON.stringify({ type: "release", feed, build: state.build, version: state.version, at: state.at });
}

// Comments and CDATA are dropped before any scan, so an <item> or a version
// quoted inside release notes is never read as a release.
const OPAQUE = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>/g;
const ITEM = /<item(?:\s[^>]*)?>([\s\S]*?)<\/item>/g;
const DELTAS = /<sparkle:deltas>[\s\S]*?<\/sparkle:deltas>/g;
const VERSION_ELEMENT = /<sparkle:version>\s*([^<]*?)\s*<\/sparkle:version>/g;
const VERSION_ATTRIBUTE = /\ssparkle:version\s*=\s*"([^"]*)"/g;
const SHORT_ELEMENT = /<sparkle:shortVersionString>\s*([^<]*?)\s*<\/sparkle:shortVersionString>/;
const SHORT_ATTRIBUTE = /\ssparkle:shortVersionString\s*=\s*"([^"]*)"/;
const SAFE_SHORT_VERSION = /^[0-9A-Za-z.+_-]{1,64}$/;

/** One item's build, or null when the item names none or more than one. */
function itemBuild(body: string): number | null {
  const found = new Set<string>();
  // Element and enclosure-attribute forms together: an item that names two
  // different builds is malformed, whichever forms they use.
  for (const match of body.matchAll(VERSION_ELEMENT)) found.add(match[1] ?? "");
  for (const match of body.matchAll(VERSION_ATTRIBUTE)) found.add(match[1] ?? "");
  if (found.size !== 1) return null;
  const [raw] = found;
  if (!raw || !/^[0-9]{1,16}$/.test(raw)) return null;
  const build = Number(raw);
  return Number.isSafeInteger(build) && build > 0 ? build : null;
}

/** The highest sparkle:version among the appcast's well-formed items, with its
 * short version. Items with no build, a non-integer build or conflicting builds
 * are skipped; an appcast with no usable item is null. */
export function parseNewestRelease(xml: string): { build: number; version: string } | null {
  let newest: { build: number; version: string } | null = null;
  for (const item of xml.replace(OPAQUE, "").matchAll(ITEM)) {
    // A delta's enclosure carries the build it updates FROM; never read it as the item's own.
    const body = (item[1] ?? "").replace(DELTAS, "");
    const build = itemBuild(body);
    if (build === null || (newest && build <= newest.build)) continue;
    const short = (SHORT_ELEMENT.exec(body) ?? SHORT_ATTRIBUTE.exec(body))?.[1] ?? "";
    newest = { build, version: SAFE_SHORT_VERSION.test(short) ? short : "" };
  }
  return newest;
}

/** What the feed object needs from its runtime; the DO passes storage, alarms,
 * fetch and its sockets, tests pass fakes. */
export interface ReleaseFeedHost {
  now(): number;
  /** The appcast body, or null on any failure (status, size, timeout). */
  fetchAppcast(url: string): Promise<string | null>;
  load(): Promise<ReleaseState | null>;
  save(state: ReleaseState): Promise<void>;
  /** Start of the last appcast read (epoch ms), kept in storage so the
   * coalescing window survives eviction; 0 when the feed was never read. */
  loadReadAt(): Promise<number>;
  saveReadAt(at: number): Promise<void>;
  broadcast(frame: string): void;
  getAlarm(): Promise<number | null>;
  setAlarm(at: number): Promise<void>;
}

/** One feed's state machine: coalesced appcast reads, a monotonic build, and
 * the frame every socket receives. */
export class ReleaseFeedCore {
  /** The newest frame this instance stored or loaded, read synchronously by a
   * socket joining right after an await (so it never gets an older frame than
   * a broadcast it missed). */
  latestFrame: string | null = null;

  constructor(private readonly feed: ReleaseFeedId, private readonly host: ReleaseFeedHost) {}

  /** A publisher or the cron says the feed may have changed. Reads now, or, if
   * a read started inside the coalescing window, arms one alarm for the window's
   * end so the poke is never lost. Returns the stored build after that. */
  async poke(): Promise<{ build: number | null }> {
    const now = this.host.now();
    const lastReadAt = await this.host.loadReadAt();
    if (now - lastReadAt >= POKE_COALESCE_MS) {
      await this.read();
    } else {
      const due = lastReadAt + POKE_COALESCE_MS;
      // An object has one alarm. Anything but this window's due time is stale
      // (armed for an earlier window whose read already ran) and is replaced,
      // so the last poke always has a read at or after it.
      const armed = await this.host.getAlarm();
      if (armed !== due) await this.host.setAlarm(due);
    }
    return { build: (await this.host.load())?.build ?? null };
  }

  /** The coalesced read the alarm deferred. One-shot: it re-arms nothing. A
   * read that already started at or after the alarm's due time covered every
   * poke that armed it, so the alarm then does nothing. */
  async alarm(): Promise<void> {
    if (this.host.now() - (await this.host.loadReadAt()) >= POKE_COALESCE_MS) await this.read();
  }

  /** The current frame for a new socket or `/latest`, reading the feed first
   * when this object has never stored a build. Null while the feed is unreadable. */
  async current(): Promise<string | null> {
    let state = await this.host.load();
    if (!state && this.host.now() - (await this.host.loadReadAt()) >= POKE_COALESCE_MS) {
      await this.read();
      state = await this.host.load();
    }
    if (state) this.latestFrame = releaseFrame(this.feed, state);
    return this.latestFrame;
  }

  private async read(): Promise<void> {
    const startedAt = this.host.now();
    // Recorded before the fetch: storage calls keep the input gate shut, so a
    // second poke arriving during the fetch already sees this read and coalesces.
    await this.host.saveReadAt(startedAt);
    const text = await this.host.fetchAppcast(`${RELEASE_FEEDS[this.feed]}?t=${startedAt}`);
    const newest = text === null ? null : parseNewestRelease(text);
    if (!newest) return;
    // load and save are storage calls, which keep the object's input gate shut,
    // so no other read can interleave between this compare and this write.
    const stored = await this.host.load();
    if (stored && newest.build <= stored.build) return;
    const state: ReleaseState = { ...newest, at: new Date(this.host.now()).toISOString() };
    await this.host.save(state);
    this.latestFrame = releaseFrame(this.feed, state);
    this.host.broadcast(this.latestFrame);
  }
}

/** Fetches one allowlisted appcast past every cache, bounded in time and size. */
export async function fetchAppcast(url: string, fetcher: typeof fetch = fetch): Promise<string | null> {
  try {
    const response = await fetcher(url, {
      headers: { "cache-control": "no-cache", pragma: "no-cache", accept: "application/rss+xml, application/xml, text/xml" },
      // A redirect is a non-2xx answer here, so it is refused below, never followed.
      redirect: "manual",
      signal: AbortSignal.timeout(APPCAST_FETCH_TIMEOUT_MS),
    });
    const declared = Number(response.headers.get("content-length") ?? "0");
    if (!response.ok || !response.body || declared > MAX_APPCAST_BYTES) {
      await response.body?.cancel();
      return null;
    }
    // Counted in bytes as they stream, and cut off at the cap: an oversized
    // body is never buffered whole.
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let bytes = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_APPCAST_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
    const body = new Uint8Array(bytes);
    let offset = 0;
    for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
    return new TextDecoder().decode(body);
  } catch {
    return null;
  }
}

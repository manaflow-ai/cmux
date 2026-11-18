// `idempotency_key` for the cloud MCP tools that act (plans/mcp-everything/ergonomics.md
// section 5): a retry with the same key from the same caller within the TTL returns the
// first result instead of acting twice. Concurrent calls with one key share the first
// call's run; the same key with other arguments is refused; a call that fails is forgotten
// so a retry acts again. Bounded in size and age.
//
// The cache is per server instance: a retry that reaches another instance acts again. That
// covers the common case (a host retrying a timed-out call on the same connection) without
// a store; a durable ledger belongs with the backend when this server moves to cmux-platform.

export const IDEMPOTENCY_KEY_ARG = "idempotency_key";
export const IDEMPOTENCY_TTL_MS = 10 * 60 * 1000;
export const IDEMPOTENCY_MAX_ENTRIES = 1000;
const MAX_KEY_LENGTH = 128;
const KEY_PATTERN = /^[A-Za-z0-9._:@/+=-]+$/;

export const idempotencyKeySchema = {
  type: "string",
  description:
    "Optional. A retry with the same key within 10 minutes returns the first result (structuredContent.replayed: true) " +
    "instead of acting twice. Echoed in structuredContent.idempotency_key.",
} as const;

export type IdempotencyKeyCheck =
  | { readonly ok: true; readonly key: string | null }
  | { readonly ok: false; readonly message: string };

/** The key in `args`, or null when absent; a malformed key is refused. */
export function readIdempotencyKey(args: Record<string, unknown>): IdempotencyKeyCheck {
  const value = args[IDEMPOTENCY_KEY_ARG];
  if (value === undefined || value === null) return { ok: true, key: null };
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_KEY_LENGTH || !KEY_PATTERN.test(value)) {
    return { ok: false, message: `\`${IDEMPOTENCY_KEY_ARG}\` must be 1-${MAX_KEY_LENGTH} characters of [A-Za-z0-9._:@/+=-].` };
  }
  return { ok: true, key: value };
}

type Entry<T> = { readonly at: number; readonly fingerprint: string; readonly result: Promise<T> };

export class IdempotencyConflict extends Error {}

/** Remembered keys and their first results, oldest first (Map keeps insertion order). */
export class IdempotencyCache<T> {
  private readonly entries = new Map<string, Entry<T>>();

  constructor(
    private readonly ttlMs = IDEMPOTENCY_TTL_MS,
    private readonly maxEntries = IDEMPOTENCY_MAX_ENTRIES,
    private readonly now: () => number = Date.now,
  ) {}

  get size(): number {
    return this.entries.size;
  }

  /**
   * `run()` at most once per `scope` and `key` while the key is remembered. Resolves to
   * `{result, replayed}`; throws `IdempotencyConflict` for the same key with another
   * `fingerprint`. `failed(result)` says a result is a failure to forget.
   */
  async once(
    scope: string,
    key: string,
    fingerprint: string,
    run: () => Promise<T>,
    failed: (result: T) => boolean,
  ): Promise<{ readonly result: T; readonly replayed: boolean }> {
    const id = `${scope}\u0000${key}`;
    const now = this.now();
    const live = this.entries.get(id);
    if (live && now - live.at < this.ttlMs) {
      if (live.fingerprint !== fingerprint) throw new IdempotencyConflict(key);
      return { result: await live.result, replayed: true };
    }
    if (live) this.entries.delete(id);
    this.evict(now);
    const result = run();
    const entry: Entry<T> = { at: now, fingerprint, result };
    this.entries.set(id, entry);
    const forget = () => {
      if (this.entries.get(id) === entry) this.entries.delete(id);
    };
    try {
      const value = await result;
      if (failed(value)) forget();
      return { result: value, replayed: false };
    } catch (error) {
      forget();
      throw error;
    }
  }

  private evict(now: number): void {
    for (const [id, entry] of this.entries) {
      if (now - entry.at < this.ttlMs && this.entries.size < this.maxEntries) break;
      this.entries.delete(id);
    }
  }
}

/** A stable fingerprint of the arguments the act depends on (key order ignored). */
export function argumentsFingerprint(args: Record<string, unknown>): string {
  const sorted = Object.keys(args).filter((k) => k !== IDEMPOTENCY_KEY_ARG).sort();
  return JSON.stringify(sorted.map((k) => [k, args[k]]));
}

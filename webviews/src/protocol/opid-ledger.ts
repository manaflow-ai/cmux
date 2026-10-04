// Provider side of decision 31: apply each opid once. A resend of an opid the provider already
// ran (a client reconnected and resent an intent it never saw answered) gets the first run's
// result or error and runs nothing. Keyed by the caller's identity (the token's `sub`, the page
// instance), because a resend arrives on a new connection.

export interface OpidLedgerOptions {
  /** Most opids remembered per caller (default 1024). */
  limit?: number;
  /** How long an answer is remembered, in ms (default 10 minutes). */
  ttlMs?: number;
  now?: () => number;
}

interface Entry {
  at: number;
  answer: Promise<unknown>;
}

export class OpidLedger {
  private readonly callers = new Map<string, Map<string, Entry>>();
  private readonly limit: number;
  private readonly ttlMs: number;
  private readonly now: () => number;

  constructor(options: OpidLedgerOptions = {}) {
    this.limit = options.limit ?? 1024;
    this.ttlMs = options.ttlMs ?? 10 * 60 * 1000;
    this.now = options.now ?? Date.now;
  }

  /**
   * Runs `apply` for a new opid; returns the remembered answer for a known one. A call without an
   * opid always runs. A refused run is remembered too: a resend gets the same refusal.
   */
  run<T>(caller: string, opid: string | undefined, apply: () => T | Promise<T>): Promise<T> {
    if (opid === undefined) return Promise.resolve().then(apply);
    let entries = this.callers.get(caller);
    if (!entries) {
      entries = new Map();
      this.callers.set(caller, entries);
    }
    const time = this.now();
    const known = entries.get(opid);
    if (known && time - known.at <= this.ttlMs) return known.answer as Promise<T>;
    const answer = Promise.resolve().then(apply);
    entries.delete(opid);
    entries.set(opid, { at: time, answer });
    for (const [key, entry] of entries) {
      if (entries.size <= this.limit && time - entry.at <= this.ttlMs) break;
      entries.delete(key);
    }
    return answer;
  }

  /** True when `opid` already ran for `caller` and is still remembered. */
  has(caller: string, opid: string): boolean {
    const entry = this.callers.get(caller)?.get(opid);
    return entry !== undefined && this.now() - entry.at <= this.ttlMs;
  }
}

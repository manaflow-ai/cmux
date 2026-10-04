import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { MuxHost } from "../src/host.ts";
import { muxPaths } from "../src/paths.ts";
import { FakeAcpmux } from "./fakes/fake-acpmux.ts";
import { FakeDaemon } from "./fakes/fake-daemon.ts";

/** A scratch MUX_HOME and both fake owners, under a short /tmp path (Unix socket length limit). */
export async function world() {
  const dir = mkdtempSync("/tmp/muxt-");
  const daemon = new FakeDaemon(join(dir, "d.sock"));
  const acpmux = new FakeAcpmux(join(dir, "a.sock"));
  await daemon.start();
  await acpmux.start();
  const home = join(dir, "home");
  const lines: string[] = [];
  const hosts: MuxHost[] = [];
  const host = (extra: { agentToken?: string; clock?: FakeClock; requestTimeoutMs?: number } = {}) => {
    const h = new MuxHost({
      ...extra,
      daemonSocket: daemon.path,
      acpmuxSocket: acpmux.path,
      paths: muxPaths(home),
      harness: "claude-sr",
      policy: "approve-all",
      displayName: "Test User",
      self: [process.execPath, join(import.meta.dir, "../src/main.ts")],
      sessionEnv: { MUX_HOME: home, ACPMUX_SOCKET: acpmux.path },
      mcpServers: [],
      log: (line) => lines.push(line),
      backoff: { initialMs: 20, maxMs: 200 },
    });
    hosts.push(h);
    return h;
  };
  const close = async () => {
    for (const h of hosts) await h.stop();
    await daemon.stop();
    await acpmux.stop();
    rmSync(dir, { recursive: true, force: true });
  };
  return { dir, home, daemon, acpmux, host, lines, close };
}

/** A promise the test resolves to end a held acpmux turn. */
export function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

/** The world's reconnect backoff (initialMs 20, maxMs 200): the longest wait advanceUntil may skip. */
export const MAX_BACKOFF_MS = 200;

/** A clock for request timeouts and backoff that only moves when the test advances it. */
export interface FakeClock {
  setTimeout(fn: () => void, ms: number): number;
  clearTimeout(handle: unknown): void;
  now(): number;
  /** Milliseconds since the epoch on this clock (it starts at 2026-10-03T00:00:00Z). */
  nowMs(): number;
  advance(ms: number): void;
  /**
   * Advances to the earliest armed timer and fires it (and any due with it),
   * when it is at most `limitMs` away; returns whether it moved.
   */
  advanceToNext(limitMs: number): boolean;
}

export function fakeClock(): FakeClock {
  let now = 1_790_985_600_000;
  let next = 1;
  const timers = new Map<number, { at: number; fn: () => void }>();
  const fireDue = () => {
    for (const [handle, timer] of [...timers].sort((a, b) => a[1].at - b[1].at)) {
      if (timer.at > now) continue;
      timers.delete(handle);
      timer.fn();
    }
  };
  return {
    setTimeout(fn, ms) {
      const handle = next++;
      timers.set(handle, { at: now + ms, fn });
      return handle;
    },
    clearTimeout(handle) {
      timers.delete(handle as number);
    },
    now: () => now,
    nowMs: () => now,
    advance(ms) {
      now += ms;
      fireDue();
    },
    advanceToNext(limitMs) {
      const earliest = Math.min(...[...timers.values()].map((t) => t.at));
      if (!Number.isFinite(earliest) || earliest - now > limitMs) return false;
      now = Math.max(now, earliest);
      fireDue();
      return true;
    },
  };
}

/**
 * Moves the fake clock to the next armed timer within one backoff (never a
 * request deadline, which is longer), with short real waits between moves,
 * until `done` holds: a reconnect backoff is armed only after the old
 * connection's close event. Returns the fake time used; throws when `done`
 * never holds.
 */
export async function advanceUntil(clock: FakeClock, done: () => boolean, limitMs = MAX_BACKOFF_MS): Promise<number> {
  const start = clock.now();
  for (let i = 0; i < 300; i++) {
    if (done()) return clock.now() - start;
    await Bun.sleep(10);
    if (done()) return clock.now() - start;
    clock.advanceToNext(limitMs);
  }
  throw new Error(`advanceUntil: not done after ${clock.now() - start} fake ms`);
}

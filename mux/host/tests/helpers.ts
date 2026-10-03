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

/** A clock for request timeouts that only moves when the test advances it. */
export interface FakeClock {
  setTimeout(fn: () => void, ms: number): number;
  clearTimeout(handle: unknown): void;
  advance(ms: number): void;
}

export function fakeClock(): FakeClock {
  let now = 0;
  let next = 1;
  const timers = new Map<number, { at: number; fn: () => void }>();
  return {
    setTimeout(fn, ms) {
      const handle = next++;
      timers.set(handle, { at: now + ms, fn });
      return handle;
    },
    clearTimeout(handle) {
      timers.delete(handle as number);
    },
    advance(ms) {
      now += ms;
      for (const [handle, timer] of [...timers].sort((a, b) => a[1].at - b[1].at)) {
        if (timer.at > now) continue;
        timers.delete(handle);
        timer.fn();
      }
    },
  };
}

/** Advances the fake clock in steps (real time between them) until `done` holds: a reconnect backoff is armed only after the old connection's close event. */
export async function advanceUntil(clock: FakeClock, done: () => boolean, stepMs = 1_000): Promise<void> {
  for (let i = 0; i < 200 && !done(); i++) {
    await Bun.sleep(10);
    // Check again after the wait: one step too many would fire the new connection's own deadline.
    if (done()) return;
    clock.advance(stepMs);
  }
}

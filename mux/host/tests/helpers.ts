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
  const host = (extra: { agentToken?: string } = {}) => {
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

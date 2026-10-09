import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { HostClient } from "../src/client.ts";
import { HostCore, type HostCoreOptions } from "../src/host.ts";
import type { HarnessSpec } from "../src/providers/harnesses.ts";
import { createOpenLoopbackPair } from "../src/transport/loopback.ts";

export const FAKE_AGENT = join(fileURLToPath(new URL(".", import.meta.url)), "fixtures", "fake-acp-agent.mjs");

export function tempDir(): string {
  return mkdtempSync(join(tmpdir(), "cnh-test-"));
}

export function fakeHarnesses(): HarnessSpec[] {
  return ["claude", "codex"].map((id) => ({
    id,
    name: id === "claude" ? "Claude Code" : "Codex",
    command: process.execPath,
    args: [FAKE_AGENT],
    detect: async () => true,
    initials: id.slice(0, 2).toUpperCase(),
    tint: "#000000",
  }));
}

export async function connectedCore(opts: HostCoreOptions = {}) {
  const dir = tempDir();
  const core = new HostCore({
    hostId: "h_test",
    hostName: "test-mac",
    browser: { launch: false, resolveEndpoint: async () => null },
    agents: { harnesses: fakeHarnesses(), dir: join(dir, "sessions") },
    conversationsPath: join(dir, "conversations.json"),
    ...opts,
  });
  const [phone, host] = createOpenLoopbackPair();
  core.attach(host);
  const client = new HostClient(phone);
  await client.hello("test");
  return { core, client, phone, dir };
}

export async function waitFor<T>(fn: () => T | undefined | null | false, timeoutMs = 10_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const v = fn();
    if (v) return v;
    if (Date.now() > deadline) throw new Error("waitFor timed out");
    await new Promise((r) => setTimeout(r, 20));
  }
}

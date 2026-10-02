import { afterEach, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { AGENT_MUX, messageText, USER_LOCAL } from "../src/conversation-types.ts";
import { FakeDaemon } from "./fakes/fake-daemon.ts";

// The `mux` executable as the app runs it: `mux host --daemon-socket ...
// --mux-home ...` with ACPMUX_BIN/ACPMUX_HOME/ACPMUX_SOCKET, the acpmux daemon
// not running yet, and a second launch that must exit 0.

const main = join(import.meta.dir, "../src/main.ts");
const cleanups: (() => void | Promise<void>)[] = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function kill(pid: number) {
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    // Gone.
  }
}

test("mux host starts the acpmux daemon, answers a message, and a second launch exits 0", async () => {
  const dir = mkdtempSync("/tmp/muxc-");
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const daemon = new FakeDaemon(join(dir, "d.sock"));
  await daemon.start();
  cleanups.push(() => daemon.stop());
  const acpmuxHome = join(dir, "acpmux");
  const bin = join(dir, "acpmux-bin");
  writeFileSync(bin, `#!/bin/sh\nexec ${process.execPath} ${join(import.meta.dir, "fakes/fake-acpmux-main.ts")} "$@"\n`);
  chmodSync(bin, 0o755);
  const env = {
    PATH: "/usr/bin:/bin",
    HOME: dir,
    ACPMUX_HOME: acpmuxHome,
    ACPMUX_SOCKET: join(acpmuxHome, "acpmux.sock"),
    ACPMUX_BIN: bin,
  };
  const argv = [process.execPath, main, "host", "--daemon-socket", daemon.path, "--mux-home", join(dir, "home")];
  const first = Bun.spawn(argv, { env, stdout: "pipe", stderr: "pipe" });
  cleanups.push(() => {
    first.kill();
    try {
      kill(Number(readFileSync(join(acpmuxHome, "fake.pid"), "utf8")));
    } catch {
      // Never started.
    }
  });
  await daemon.until(() => daemon.conversationIds.length === 1 && daemon.subscriberCount === 1);
  const [conv] = daemon.conversationIds;
  daemon.send(conv, USER_LOCAL, "hi from the app");
  await daemon.until(() => daemon.messages(conv).some((m) => m.author === AGENT_MUX));
  expect(messageText(daemon.messages(conv).find((m) => m.author === AGENT_MUX)!)).toBe(`echo: [conversation ${conv} from ${daemon.conversation(conv).summary.participants[0].display_name}] hi from the app`);

  const second = Bun.spawn(argv, { env, stdout: "pipe", stderr: "pipe" });
  expect(await second.exited).toBe(0);
  expect(await new Response(second.stderr).text()).toContain("already running");

  first.kill("SIGTERM");
  expect(await first.exited).toBe(0);
  const log = await new Response(first.stderr).text();
  expect(log).toContain("started acpmux daemon");
});

test("mux hook user-prompt-submit logs to memory and session-start shows it", async () => {
  const dir = mkdtempSync("/tmp/muxh-");
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const env = { PATH: "/usr/bin:/bin", HOME: dir, MUX_HOME: join(dir, "home") };
  const run = async (args: string[], stdin: unknown) => {
    const child = Bun.spawn([process.execPath, main, ...args], { env, stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe" });
    const [out, code] = await Promise.all([new Response(child.stdout).text(), child.exited]);
    expect(code).toBe(0);
    return out;
  };
  await run(["hook", "user-prompt-submit"], { session_id: "aaaaaaaa-1", prompt: "remember the deploy is on fridays" });
  await run(["hook", "stop"], { session_id: "aaaaaaaa-1", last_assistant_message: "noted" });
  const start = JSON.parse(await run(["hook", "session-start"], { session_id: "bbbbbbbb-2" }));
  expect(start.hookSpecificOutput.additionalContext).toContain("deploy is on fridays");
  const recall = Bun.spawnSync([process.execPath, main, "memory", "recall", "fridays"], { env });
  expect(recall.stdout.toString()).toContain("user: remember the deploy is on fridays");
});

import { afterEach, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
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
  const tokenFile = join(dir, "agent-token");
  writeFileSync(tokenFile, "cli-token\n", { mode: 0o600 });
  const env = {
    PATH: "/usr/bin:/bin",
    HOME: dir,
    ACPMUX_HOME: acpmuxHome,
    ACPMUX_SOCKET: join(acpmuxHome, "acpmux.sock"),
    ACPMUX_BIN: bin,
    MUX_AGENT_TOKEN_FILE: tokenFile,
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
  await daemon.until(() => daemon.bindings.length === 1);
  expect(daemon.bindings[0]).toEqual({ participant: AGENT_MUX, token: "cli-token" });
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

test("mux hook recovers from a malformed seen cursor", async () => {
  const dir = mkdtempSync("/tmp/muxh-bad-");
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const home = join(dir, "home");
  const env = { PATH: "/usr/bin:/bin", HOME: dir, MUX_HOME: home };
  const run = async (input: unknown) => {
    const child = Bun.spawn([process.execPath, main, "hook", "user-prompt-submit"], {
      env,
      stdin: new Blob([JSON.stringify(input)]),
      stdout: "pipe",
      stderr: "pipe",
    });
    const [out, code, err] = await Promise.all([
      new Response(child.stdout).text(),
      child.exited,
      new Response(child.stderr).text(),
    ]);
    expect(code, err).toBe(0);
    return out;
  };
  const cursor = join(home, "state", "sessions", "bad-session.json");
  for (const malformed of ["", "{\"seen\":", "null", "[]", "{\"seen\":\"old\"}"]) {
    mkdirSync(join(home, "state", "sessions"), { recursive: true });
    writeFileSync(cursor, malformed);
    await run({ session_id: "bad-session", prompt: "recover this hook" });
    expect(JSON.parse(readFileSync(cursor, "utf8"))).toEqual({ seen: expect.any(Number) });
  }
});

test("mux hook removes its temporary cursor when the write fails", () => {
  const dir = mkdtempSync("/tmp/muxh-full-");
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const home = join(dir, "home");
  const sessions = join(home, "state", "sessions");
  mkdirSync(sessions, { recursive: true });
  // A zero file-size limit (with SIGXFSZ ignored) lets the temporary cursor be created and
  // then fails its write with EFBIG, as a full disk would.
  const run = Bun.spawnSync(
    ["/bin/sh", "-c", `trap '' XFSZ; ulimit -f 0; exec "${process.execPath}" "${main}" hook session-start`],
    {
      env: { PATH: "/usr/bin:/bin", HOME: dir, MUX_HOME: home },
      stdin: new Blob([JSON.stringify({ session_id: "full-disk" })]),
    },
  );
  expect(run.exitCode, run.stderr.toString()).not.toBe(0);
  expect(run.stderr.toString()).toContain("EFBIG");
  expect(readdirSync(sessions)).toEqual([]);
});

test("mux hook sweeps temporary cursors a killed hook left behind", () => {
  const dir = mkdtempSync("/tmp/muxh-stale-");
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const home = join(dir, "home");
  const sessions = join(home, "state", "sessions");
  mkdirSync(sessions, { recursive: true });
  // A hook killed between its write and its rename leaves its temporary cursor behind.
  // No live process has this PID (Linux caps PIDs at 2^22, macOS lower still).
  const dead = 2147483646;
  const stale = join(sessions, `killed.json.${dead}.1.ab.tmp`);
  const fresh = join(sessions, `killed.json.${dead}.2.cd.tmp`);
  // A hook paused between its write and its rename still owns its temporary, however old.
  const paused = join(sessions, `killed.json.${process.pid}.3.ef.tmp`);
  const other = join(sessions, `other.json.${dead}.4.ab.tmp`);
  // Session "killed.json" is another session whose temporaries share the prefix.
  const lookalike = join(sessions, `killed.json.json.${dead}.5.cd.tmp`);
  for (const file of [stale, fresh, paused, other, lookalike]) writeFileSync(file, '{"seen":1}\n');
  const old = new Date(Date.now() - 10 * 60_000);
  for (const file of [stale, paused, other, lookalike]) utimesSync(file, old, old);
  const run = Bun.spawnSync([process.execPath, main, "hook", "session-start"], {
    env: { PATH: "/usr/bin:/bin", HOME: dir, MUX_HOME: home },
    stdin: new Blob([JSON.stringify({ session_id: "killed" })]),
  });
  expect(run.exitCode, run.stderr.toString()).toBe(0);
  // Only its own stale temporary of a dead hook goes; a fresh one may belong to a hook
  // still writing, and other sessions' temporaries are those sessions' to sweep.
  expect(readdirSync(sessions).sort()).toEqual(
    [
      "killed.json",
      `killed.json.${dead}.2.cd.tmp`,
      `killed.json.${process.pid}.3.ef.tmp`,
      `killed.json.json.${dead}.5.cd.tmp`,
      `other.json.${dead}.4.ab.tmp`,
    ].sort(),
  );
});

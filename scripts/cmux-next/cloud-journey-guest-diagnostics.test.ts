import { expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Journey, resolveBackend } from "./cloud-journey";
import { collectGuestDiagnostics, guestDiagnosticsFacts, GUEST_UPDATER_DIAGNOSTICS } from "./cloud-journey-guest-diagnostics";

const ok = (stdout: string) => ({ code: 0, stdout });
const commit = "e38450656520d892ad5353d05dc97d568a167232";
const digest = "d83f49a5391c5b92ccd3ce2b77201ec9c8f8896547fb93f130703ba11f5fa073";

test("a failed journey retains guest updater evidence separately from the truncated step table", async () => {
  const dir = mkdtempSync(join(tmpdir(), "journey-guest-evidence-"));
  try {
    const journey = new Journey(resolveBackend("staging"), dir, {});
    const receipt = { phase: "before-cleanup", collected_at: "2026-11-19T12:55:00Z", status: "unavailable", reason: "no exec route" };
    Object.assign(journey, { guestDiagnostics: [receipt] });
    await expect(journey.step("turn after resume", async () => { throw new Error("not signed in"); })).rejects.toThrow("not signed in");
    const evidence = JSON.parse(readFileSync(join(dir, "guest-updater.json"), "utf8"));
    expect(evidence.observations).toEqual([receipt]);
    expect(JSON.parse(readFileSync(join(dir, "journey.json"), "utf8")).steps[0].status).toBe("fail");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("store guest evidence preserves Rust updater holds, first-ready timing and actual executable", () => {
  const facts = guestDiagnosticsFacts({
    units: { "cmux-host.service": { ...ok("LoadState=loaded\nActiveState=active\nMainPID=123\nExecStart={ path=/opt/cmux/current/bin/cmux ; argv[]=/opt/cmux/current/bin/cmux host run --mode system ; }"), executable: ok(`/opt/cmux/store/${digest}/cmux-tui`) } },
    store: ok("/opt/cmux/profiles/3\n"),
    versions: { "cmux-tui": ok(`cmux 1.0.0 (${commit}; ghostty 123abc)`), acpmux: ok("acpmux 1.0.0 (325ccecb4 2026-11-18)") },
    updater: ok(JSON.stringify({ off: null, current: 3, cmux_tui: digest, pending: null, state: {
      applied_commit: commit, look: { outcome: "held", reason: "connect-hold", at: 12000, waited: "held:connect-hold" },
      first_ready: { image_behind: true, from_version: "a".repeat(64), to_version: digest, channel_commit: commit,
        started_at: 1000, finished_at: 1100, check_ms: 100, update_ms: 100, outcome: "updated" },
    } })),
  });
  expect(facts.supervisor["cmux-host.service"].executable).toBe(`/opt/cmux/store/${digest}/cmux-tui`);
  expect(facts.supervisor["cmux-host.service"].exec_start.argv).toEqual(["/opt/cmux/current/bin/cmux", "host", "run", "--mode", "system"]);
  expect(facts.store_link).toBe("/opt/cmux/profiles/3");
  expect(facts.versions["cmux-tui"]).toEqual({ version: "1.0.0", commit });
  expect(facts.updater.look.reason).toBe("connect-hold");
  expect(facts.updater.first_ready.update_ms).toBe(100);
  expect(facts.updater.first_ready.channel_commit).toBe(commit);
});

test("old, unreadable and unsupported guests say unavailable; absent times never become zero", () => {
  for (const updater of [undefined, { code: 1, stdout: "password required" }, ok("unsupported command"), ok("{}"), ok(JSON.stringify({ state: {} }))]) {
    const facts = guestDiagnosticsFacts({ updater });
    expect(facts.store_link).toBe("unavailable");
    expect(facts.updater.first_ready.status).toBe("unavailable");
    expect(facts.updater.first_ready.update_ms).toBe("unavailable");
    expect(facts.updater.look.outcome).toBe("unavailable");
  }
  expect(guestDiagnosticsFacts({ updater: ok(JSON.stringify({ state: { first_ready: { update_ms: 0, image_behind: false } } })) }).updater.first_ready.update_ms).toBe(0);
});

test("no credentials or arbitrary argv, error text or unknown fields survive publication", () => {
  const secret = "unknown-sensitive-credential";
  const facts = guestDiagnosticsFacts({
    token: secret, store: ok(`/tmp/${secret}`), versions: { acpmux: ok(secret) },
    units: { "cmux-host.service": ok(`LoadState=${secret}\nExecStart={ path=/bin/${secret} ; argv[]=/opt/cmux/current/bin/cmux host run --token ${secret} ; }`) },
    updater: ok(JSON.stringify({ off: `/home/cmux/.cmux/bin/cmux-tui points at /tmp/${secret}`, auth: secret, state: {
      last: secret, look: { outcome: secret, reason: secret, waited: secret },
      first_ready: { channel_commit: secret, outcome: secret, update_ms: secret },
    } })),
  });
  expect(JSON.stringify(facts)).not.toContain(secret);
  expect(facts.updater.off_reason).toBe("work-link-replaced");
  expect(facts.supervisor["cmux-host.service"].exec_start.argv).toContain("[redacted]");
});

test("collection failures are evidence and never replace the lifecycle verdict", async () => {
  const missing = await collectGuestDiagnostics(null, "before-cleanup");
  expect(missing.status).toBe("unavailable");
  expect(missing.reason).toBe("no exec route");
  const refused = await collectGuestDiagnostics(async () => { throw new Error("a private credential"); }, "before-cleanup");
  expect(JSON.stringify(refused)).not.toContain("private credential");
  expect(refused.updater.first_ready.update_ms).toBe("unavailable");
  const timed = await collectGuestDiagnostics(async () => new Promise(() => {}), "before-cleanup", 1);
  expect(timed.status).toBe("unavailable");
  const controller = new AbortController();
  const pending = collectGuestDiagnostics(async () => new Promise(() => {}), "before-cleanup", 18_000, controller.signal);
  controller.abort();
  expect((await pending).status).toBe("unavailable");
});

test("guest probe executes read-only version/status commands and tolerates a legacy machine", () => {
  // Run the actual guest program with fake systemctl/versions; never ask the test host for sudo.
  const dir = mkdtempSync(join(tmpdir(), "journey-guest-probe-"));
  try {
    for (const name of ["systemctl", "readlink", "cmux-tui", "acpmux", "sudo"]) {
      const file = join(dir, name);
      writeFileSync(file, `#!/bin/sh\nprintf '%s\\n' "$0 $*" >> '${dir}/calls'\nexit 1\n`);
      chmodSync(file, 0o755);
    }
    const result = Bun.spawnSync(["sh", "-c", GUEST_UPDATER_DIAGNOSTICS], { env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, HOME: dir } });
    expect(result.exitCode).toBe(0);
    expect(guestDiagnosticsFacts(JSON.parse(result.stdout.toString())).updater.status).toBe("unavailable");
    const calls = readFileSync(join(dir, "calls"), "utf8");
    expect(calls).not.toMatch(/update (check|adopt)|restart|Environment/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

import { describe, expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { aptUpdateCommand } from "../scripts/cmux-vm-image/apt-update";
import * as bake from "../scripts/cmux-vm-image/bake";
import { cmuxTuiSourceFromLock, GUEST_DIR } from "../scripts/cmux-vm-image/bake";
import { CURRENT_BIN, profileCommand, programInstallCommand, readInputsLock, storeEntry } from "../scripts/cmux-vm-image/lock";
import { imageLeftoversCommand, programChecksCommand, programProblems, secretScanCommand, storeCommandPathSnippet } from "../scripts/cmux-vm-image/smoke";
import { daemonHoldCommand, daemonUptimeProblems, forcedRebindCommand } from "../scripts/cmux-vm-image/daemon-uptime";
import { GH_SHIM } from "../scripts/cmux-vm-image/github-auth";
import { runChild } from "./helpers/run-child";
import { CMUX_CLOUD_HOME, CMUX_TUI_LEGACY_HOME } from "../services/vms/drivers/cmuxTuiDaemon";

const lock = readInputsLock();

async function bashSyntax(script: string): Promise<void> {
  const result = await runChild("bash", ["-n"], { input: script, timeout: 20_000 });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
}

describe("cmux VM image guest commands", () => {
  test("every store install command parses and verifies digest and size", async () => {
    for (const program of lock.programs) {
      const command = programInstallCommand(program);
      expect(command).toContain(`printf '%s  %s\\n' ${program.sha256}`);
      expect(command).toContain(`= ${program.size}`);
      expect(command).toContain(`mv ${storeEntry(program.sha256)}.partial ${storeEntry(program.sha256)}`);
      await bashSyntax(command);
    }
    expect(programInstallCommand(lock.programs.find((p) => p.name === "coderouter")!)).toContain("grep -qx");
  });

  test("the profile links every command into generation 1 and flips current with one rename", async () => {
    const command = profileCommand(lock);
    expect(command).toContain("mv -T /opt/cmux/.current-new /opt/cmux/current");
    expect(command).toContain(`ln -s ${storeEntry(lock.programs.find((p) => p.name === "coderouter")!.sha256)}/coderouter /opt/cmux/profiles/1/bin/cr`);
    await bashSyntax(command);
  });

  test("smoke scans and program checks parse", async () => {
    await bashSyntax(secretScanCommand());
    await bashSyntax(programChecksCommand(lock));
  });

  test("daemon uptime, forced rebind and image leftover commands parse", async () => {
    await bashSyntax(daemonHoldCommand());
    await bashSyntax(forcedRebindCommand());
    await bashSyntax(imageLeftoversCommand());
    // Existence only: the leftover scan never reads or prints a sign-in file's contents.
    expect(imageLeftoversCommand()).not.toMatch(/\b(cat|head -c|grep [^|]*credentials)\b/);
  });

  // Bake run 41701438675 passed with a session host that crash-looped after any rebind (cmux#34128).
  test("daemon uptime parsing: a crash loop, a fence without auth/ and the migration error fail", () => {
    const up = "pid=812\nalive=1\npid-after=812";
    expect(daemonUptimeProblems(up)).toEqual([]);
    expect(daemonUptimeProblems("pid=\nalive=0\npid-after=")).toEqual(["no session host at the start of the hold"]);
    expect(daemonUptimeProblems("pid=812\nalive=0\npid-after=901")).toEqual(["session host 812 did not stay up 60 s (now 901)"]);
    const crashLoop = [
      "pid=812",
      "alive=0",
      "pid-after=",
      "fence-without-auth=/home/cmux/.local/state/cmux/remote/sessions/Y2xvdWQ/",
      "legacy-error=cmux-tui: previous remote daemon authorization state requires explicit migration; verify that no legacy cmux-tui process remains",
      "host-exit=cmux-host: session host 2840 exited after 94 ms",
    ].join("\n");
    expect(daemonUptimeProblems(crashLoop)).toHaveLength(4);
  });

  test("program check parsing: exit code, store path and version", () => {
    // gh resolves to the GitHub shim, which runs the store's gh (3ebb4a8145d9, github-auth.ts).
    const resolves = (command: string) => (command === "gh" ? GH_SHIM : `${CURRENT_BIN}/${command}`);
    const ok = lock.programs.flatMap((p) => Object.keys(p.bin).map((c) => `${c} 0 ${resolves(c)} :: ${p.expect ?? "x"} ok`)).join("\n");
    expect(programProblems(lock, ok)).toEqual([]);
    const bad = ok.replace(`claude 0 ${CURRENT_BIN}/claude`, "claude 127 /usr/local/bin/claude");
    expect(programProblems(lock, bad)).toEqual([`claude: exit 127: ${lock.programs.find((p) => p.name === "claude")!.expect} ok`, `claude: resolves to /usr/local/bin/claude, expected ${CURRENT_BIN}/claude`]);
  });

  test("a user-local alias of the store's own binary reports as the current profile entry", async () => {
    // Bake 41401002175: ~/.local/bin/acpmux (the canonical user unit's path, cmux#31337/#31886) comes
    // first on the login PATH and points through ~/.cmux/bin/cmux-tui at the store's cmux-tui.
    const root = mkdtempSync(path.join(os.tmpdir(), "cmux-vm-alias-"));
    try {
      const store = path.join(root, "store", "cmux-tui");
      const current = path.join(root, "current", "bin");
      const local = path.join(root, "home", ".local", "bin");
      for (const dir of [path.dirname(store), current, local, path.join(root, "home", ".cmux", "bin"), path.join(root, "other")]) mkdirSync(dir, { recursive: true });
      writeFileSync(store, "#!/bin/sh\n", { mode: 0o755 });
      symlinkSync(store, path.join(current, "acpmux"));
      symlinkSync(store, path.join(current, "cmux-tui"));
      symlinkSync(path.join(current, "cmux-tui"), path.join(root, "home", ".cmux", "bin", "cmux-tui"));
      symlinkSync(path.join(root, "home", ".cmux", "bin", "cmux-tui"), path.join(local, "acpmux"));
      writeFileSync(path.join(root, "other", "claude"), "#!/bin/sh\n", { mode: 0o755 });
      writeFileSync(path.join(current, "claude"), "#!/bin/sh\n", { mode: 0o755 });
      const lookup = async (command: string) => {
        const script = `PATH=${local}:${path.join(root, "other")}:${current}:/usr/bin:/bin; ${storeCommandPathSnippet(command, current)}; printf '%s' "$p"`;
        return (await runChild("bash", ["-c", script], { timeout: 20_000 })).stdout;
      };
      expect(await lookup("acpmux")).toBe(path.join(current, "acpmux"));
      // A different file ahead of the store is still reported where it is.
      expect(await lookup("claude")).toBe(path.join(root, "other", "claude"));
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the daemon source comes from the lock, not a manifest fetch", () => {
    const source = cmuxTuiSourceFromLock(lock);
    expect(source.commit).toMatch(/^[0-9a-f]{40}$/);
    expect(source.url).toContain(source.commit);
    expect(source.hookUrl).toContain(source.commit);
  });

  test("guest python helpers parse", async () => {
    for (const file of readdirSync(GUEST_DIR).filter((f) => f.endsWith(".py"))) {
      const result = await runChild("python3", ["-c", "import ast, sys; ast.parse(open(sys.argv[1]).read())", path.join(GUEST_DIR, file)], { timeout: 20_000 });
      expect(result.status).toBe(0);
    }
  });
});

describe("Freestyle key by path", () => {
  test("FREESTYLE_API_KEY_FILE is read and trimmed; empty or absent fails closed", async () => {
    const { freestyleApiKey } = await import("../scripts/cmux-vm-image/guest");
    const { mkdtempSync, writeFileSync } = await import("node:fs");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const dir = mkdtempSync(join(tmpdir(), "fs-key-"));
    writeFileSync(join(dir, "k"), "fake-key-value\n");
    writeFileSync(join(dir, "empty"), "\n");
    expect(freestyleApiKey({ FREESTYLE_API_KEY_FILE: join(dir, "k") })).toBe("fake-key-value");
    expect(freestyleApiKey({ FREESTYLE_API_KEY: "direct", FREESTYLE_API_KEY_FILE: join(dir, "k") })).toBe("direct");
    expect(() => freestyleApiKey({ FREESTYLE_API_KEY_FILE: join(dir, "empty") })).toThrow(/empty/);
    expect(() => freestyleApiKey({})).toThrow(/FREESTYLE_API_KEY_FILE/);
  });
});

// Bake run 41018544354 (2026-10-30): snapshot.ubuntu.com answered 503 for every InRelease. `apt-get update`
// still exited 0 (warnings only), apt-cache then knew none of the pins, and the bake failed on the first
// pin alphabetically ("no size for acl=..."), which read like a bad lock.
describe("cmux VM image apt index", () => {
  test("an index outage falls back to the archive on the first failed snapshot update", async () => {
    expect(bake.APT_UPDATE_COMMAND).toContain("timeout 90s apt-get update -q --error-on=any");
    expect(bake.APT_UPDATE_COMMAND).not.toContain("then exit 0");
    expect(bake.APT_UPDATE_COMMAND).not.toContain("for attempt");
    expect(bake.APT_UPDATE_COMMAND).not.toContain("sleep 5");
    expect(bake.APT_UPDATE_COMMAND).toContain("timeout 60s apt-get update -q --error-on=any");
    expect(bake.APT_UPDATE_COMMAND).toContain("falling back to archive.ubuntu.com/security.ubuntu.com");
    const payload = bake.APT_UPDATE_COMMAND.match(/printf %s ([A-Za-z0-9+/=]+) \| base64 -d/)?.[1];
    expect(payload).toBeDefined();
    const fallbackSources = Buffer.from(payload!, "base64").toString("utf8");
    expect(fallbackSources).toContain("archive.ubuntu.com/ubuntu");
    expect(fallbackSources).toContain("security.ubuntu.com/ubuntu");
    await bashSyntax(bake.APT_UPDATE_COMMAND);
    expect(bake.APT_UPDATE_COMMAND).toBe(aptUpdateCommand({ log: "/tmp/apt-update.log", sources: "/etc/apt/sources.list.d/ubuntu.sources", saved: "/tmp/ubuntu.sources.snapshot" }));
  });

  test("an empty index is reported as one apt index problem, not the first pin", () => {
    const pins = { acl: "2.3.2-1build1.1", curl: "8.5.0-2ubuntu10.16", git: "1:2.43.0-1ubuntu7.4" };
    expect(() => bake.aptDownloadBatches(pins, new Map())).toThrow(
      "apt index has no size for 3 of 3 locked pins (acl=2.3.2-1build1.1, curl=8.5.0-2ubuntu10.16, git=1:2.43.0-1ubuntu7.4)",
    );
    expect(() => bake.aptDownloadBatches(pins, new Map([["acl=2.3.2-1build1.1", 1], ["git=1:2.43.0-1ubuntu7.4", 1]]))).toThrow(
      "apt index has no size for 1 of 3 locked pins (curl=8.5.0-2ubuntu10.16)",
    );
    expect(bake.aptDownloadBatches(pins, new Map(Object.entries(pins).map(([n, v]) => [`${n}=${v}`, 1])))).toHaveLength(1);
  });

  test("the image carries the agent sign-in files the Mac app's Cloud sign-in sources", async () => {
    expect(bake.AGENT_SIGN_IN_FILES.map((f) => f.path)).toEqual(["/etc/cmux/agent-auth.sh", "/etc/cmux/claude-onboarding.py"]);
    await bashSyntax(bake.agentSignInCheckCommand());
    const root = mkdtempSync(path.join(os.tmpdir(), "cmux-vm-agent-sign-in-"));
    try {
      mkdirSync(path.join(root, "etc/cmux"), { recursive: true });
      const devbox = path.join(import.meta.dirname, "../services/vms/images/devbox");
      for (const file of bake.AGENT_SIGN_IN_FILES) copyFileSync(path.join(devbox, file.name), path.join(root, file.path));
      const baked = await runChild("sh", ["-c", bake.agentSignInCheckCommand(root)], { timeout: 20_000 });
      expect(baked.stdout).toBe("agent-sign-in-baked\n");
      expect(baked.status).toBe(0);
      rmSync(path.join(root, "etc/cmux/agent-auth.sh"));
      const missing = await runChild("sh", ["-c", bake.agentSignInCheckCommand(root)], { timeout: 20_000 });
      expect(missing.status).not.toBe(0);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe("cmux VM image snapshot-ready check", () => {
  const homes = [CMUX_CLOUD_HOME, CMUX_TUI_LEGACY_HOME];
  async function ready(root: string, acpmuxRunning = true, findFails = false) {
    const bin = path.join(root, "stub-bin");
    mkdirSync(bin, { recursive: true });
    writeFileSync(path.join(bin, "systemctl"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    writeFileSync(path.join(bin, "pgrep"), `#!/bin/sh\nexit ${acpmuxRunning ? 0 : 1}\n`, { mode: 0o755 });
    // A scan error (an unreadable tree), whoever runs the test: root reads through a chmod 000.
    if (findFails) writeFileSync(path.join(bin, "find"), "#!/bin/sh\necho 'find: Permission denied' >&2\nexit 1\n", { mode: 0o755 });
    return runChild("bash", ["-c", bake.snapshotReadyCommand(root)], {
      env: { PATH: `${bin}:/usr/bin:/bin`, HOME: root },
      timeout: 20_000,
    });
  }

  test("passes with cmux-host and acpmux running and no per-machine file", async () => {
    const root = mkdtempSync(path.join(os.tmpdir(), "snapshot-ready-"));
    try {
      const result = await ready(root);
      expect(result.stdout).toContain("snapshot-ready");
      expect(result.status).toBe(0);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("refuses a snapshot without acpmux running", async () => {
    const root = mkdtempSync(path.join(os.tmpdir(), "snapshot-ready-"));
    try {
      expect((await ready(root, false)).status).not.toBe(0);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  async function refuses(files: string[], message: string) {
    const root = mkdtempSync(path.join(os.tmpdir(), "snapshot-ready-"));
    try {
      for (const file of files) {
        mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
        writeFileSync(path.join(root, file), "{}");
      }
      const result = await ready(root);
      expect({ files, status: result.status === 0 ? "passed" : "refused" }).toEqual({ files, status: "refused" });
      expect(result.stderr).toContain(message);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }

  test("refuses each per-machine file a clone writes at bind", async () => {
    for (const file of bake.PER_MACHINE_FILES) await refuses([file], `per-machine file in the snapshot: `);
  });

  test("refuses the session host's remote identity and machine secrets", async () => {
    // Under both layouts' homes, so the check refuses whichever one this host's layout selector picks.
    for (const rel of [
      ".local/state/cmux/remote/sessions/c2Vzc2lvbg/auth/identity.json",
      ".local/state/cmux-tui/sessions/machine-id",
      ".local/state/cmux-tui/sessions/resource-effect-pepper",
    ])
      await refuses(
        homes.map((h) => `${h}/${rel}`),
        "per-machine identity in the snapshot",
      );
  });

  test("refuses when the identity tree exists but cannot be scanned (fails closed)", async () => {
    const root = mkdtempSync(path.join(os.tmpdir(), "snapshot-ready-"));
    try {
      for (const h of homes) mkdirSync(path.join(root, h, ".local/state/cmux/remote"), { recursive: true });
      const result = await ready(root, true, true);
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("cannot scan");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("refuses an identity tree behind a symlink, which find would not scan", async () => {
    const root = mkdtempSync(path.join(os.tmpdir(), "snapshot-ready-"));
    try {
      const hidden = path.join(root, "elsewhere/sessions/c2Vzc2lvbg/auth");
      mkdirSync(hidden, { recursive: true });
      writeFileSync(path.join(hidden, "identity.json"), "{}");
      for (const h of homes) {
        mkdirSync(path.join(root, h, ".local/state/cmux"), { recursive: true });
        symlinkSync(path.join(root, "elsewhere"), path.join(root, h, ".local/state/cmux/remote"));
      }
      const result = await ready(root);
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("is a symlink");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("runs right before the snapshot, after the page cache warm and before the machine-health arm", () => {
    const source = readFileSync(new URL("../scripts/cmux-vm-image/bake.ts", import.meta.url), "utf8");
    const at = source.indexOf('L.step(vm, "snapshot-ready", snapshotReadyCommand())');
    expect(at).toBeGreaterThan(source.indexOf('"drop-cache-warm-bind-path"'));
    expect(at).toBeLessThan(source.indexOf('L.step(vm, "machine-health-arm"'));
  });

  test("covers the bind's identity receipt (cmux-host identity.rs RECEIPT)", () => {
    expect(bake.PER_MACHINE_FILES).toContain("/var/lib/cmux/install/identity.json");
  });
});

describe("cmux VM image /tmp writer after clean (image roll 42888042827: /tmp/opencode)", () => {
  const source = () => readFileSync(new URL("../scripts/cmux-vm-image/bake.ts", import.meta.url), "utf8");

  test("acpmux stays running: its harness checks finish before clean, the leftover check is last before snapshot-ready", () => {
    const bake_ = source();
    const at = (needle: string) => {
      const i = bake_.indexOf(needle);
      expect({ needle, found: i >= 0 }).toEqual({ needle, found: true });
      return i;
    };
    const loginEnv = at('L.step(vm, "acpmux-login-env"');
    const checks = at('L.step(vm, "acpmux-harness-checks", acpmuxHarnessChecksDoneCommand())');
    const clean = at('L.step(vm, "clean"');
    const tmpEmpty = at('L.step(vm, "tmp-empty"');
    const warm = at('"drop-cache-warm-bind-path"');
    const writers = at('L.step(vm, "tmp-no-writer", tmpWritersCommand())');
    const ready = at('L.step(vm, "snapshot-ready", snapshotReadyCommand())');
    expect(loginEnv).toBeLessThan(checks);
    expect(checks).toBeLessThan(clean);
    expect(clean).toBeLessThan(tmpEmpty);
    expect(warm).toBeLessThan(writers);
    expect(writers).toBeLessThan(ready);
    // Nothing runs on the builder between the leftover check and snapshot-ready.
    expect(bake_.slice(writers, ready).match(/L\.step\(/g)?.length).toBe(1);
    // acpmux is never stopped for the snapshot: snapshot-ready still requires it running.
    expect(bake.snapshotReadyCommand()).toContain("pgrep -f '[a]cpmux daemon run'");
    expect(bake_).not.toMatch(/systemctl --user (stop|disable) acpmux/);
  });

  test("the harness-check wait reads acpmux's own completion signal (harness-health.json), not a fixed sleep", () => {
    const refresh = bake.acpmuxLoginEnvRefreshCommand();
    // The saved copy goes before the restart, so its reappearance is this start's finished check.
    expect(refresh).toContain('health="$CMUX_TUI_HOME/.acpmux/harness-health.json"');
    expect(refresh.indexOf('rm -f "$cache" "$health"')).toBeGreaterThanOrEqual(0);
    expect(refresh.indexOf('rm -f "$cache" "$health"')).toBeLessThan(refresh.indexOf("systemctl --user restart acpmux.service"));
    const wait = bake.acpmuxHarnessChecksDoneCommand();
    expect(wait).toContain('"$CMUX_TUI_HOME/.acpmux/harness-health.json"');
    expect(wait).toContain('[ ! -s "$health" ]');
    expect(wait).not.toMatch(/sleep (?!1;)\d/);
    expect(wait).toContain("acpmux's harness check did not finish");
  });

  async function writers(dir: string) {
    return runChild("bash", ["-c", bake.tmpWritersCommand([dir])], { timeout: 30_000 });
  }

  test("passes when nothing was written after clean", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "tmp-writers-"));
    try {
      mkdirSync(path.join(dir, ".freestyle-exec-1"));
      const result = await writers(dir);
      expect(result.stdout).toContain("tmp-no-writer");
      expect(result.status).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("fails naming each leftover's owner, mtime and the processes that hold it open or name it", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "tmp-writers-"));
    const leftover = path.join(dir, "opencode");
    const { spawn } = await import("node:child_process");
    // One process holds the leftover open; another names it on its command line.
    const holder = spawn("bash", ["-c", 'exec 3>>"$1"; exec sleep 300', "holder", leftover], { stdio: "ignore" });
    const namer = spawn("sh", ["-c", "sleep 300; :", "namer", leftover], { stdio: "ignore" });
    try {
      for (let i = 0; i < 50 && !readdirSync(dir).includes("opencode"); i++) await new Promise((r) => setTimeout(r, 50));
      await new Promise((r) => setTimeout(r, 200));
      const result = await writers(dir);
      const out = result.stdout + result.stderr;
      expect(result.status).not.toBe(0);
      expect(out).toContain(`written after clean: ${leftover}`);
      expect(out).toMatch(/owner=\S+:\S+/);
      expect(out).toContain("mtime=");
      expect(out).toContain(`open by pid ${holder.pid}: sleep 300`);
      expect(out).toContain(`named by pid ${namer.pid}:`);
      expect(out).toContain("processes of");
    } finally {
      holder.kill("SIGKILL");
      namer.kill("SIGKILL");
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

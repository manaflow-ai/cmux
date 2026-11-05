import { describe, expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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
    const up = "pid=812\nalive=1\npid-after=812\nudp4101=0\ncloud-bound=0";
    expect(daemonUptimeProblems(up, true)).toEqual([]);
    expect(daemonUptimeProblems("pid=\nalive=0\npid-after=\nudp4101=0\ncloud-bound=0", false)).toEqual(["no session host at the start of the hold"]);
    expect(daemonUptimeProblems("pid=812\nalive=0\npid-after=901\nudp4101=0\ncloud-bound=0", false)).toEqual(["session host 812 did not stay up 60 s (now 901)"]);
    const crashLoop = [
      "pid=812",
      "alive=0",
      "pid-after=",
      "fence-without-auth=/home/cmux/.local/state/cmux/remote/sessions/Y2xvdWQ/",
      "legacy-error=cmux-tui: previous remote daemon authorization state requires explicit migration; verify that no legacy cmux-tui process remains",
      "host-exit=cmux-host: session host 2840 exited after 94 ms",
    ].join("\n");
    expect(daemonUptimeProblems(crashLoop, false)).toHaveLength(4);
    // UDP 4101 is required once the clone is bound to Cloud (the Native receiver binds after a Cloud bind).
    expect(daemonUptimeProblems(up.replace("cloud-bound=0", "cloud-bound=1"), true)).toEqual(["UDP 4101 not bound on a Cloud-bound Native receiver clone"]);
    expect(daemonUptimeProblems(up.replace("cloud-bound=0", "cloud-bound=1").replace("udp4101=0", "udp4101=1"), true)).toEqual([]);
    expect(daemonUptimeProblems(up.replace("cloud-bound=0", "cloud-bound=1"), false)).toEqual([]);
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
  test("an index outage gets one bounded retry with backoff before failing", async () => {
    expect(bake.APT_UPDATE_COMMAND).toContain("timeout \"${timeout_s}s\" apt-get update -q --error-on=any");
    expect(bake.APT_UPDATE_COMMAND).toContain("timeout_s=180");
    expect(bake.APT_UPDATE_COMMAND).toContain("apt_update_ok=1; break;");
    expect(bake.APT_UPDATE_COMMAND).not.toContain("then exit 0");
    expect(bake.APT_UPDATE_COMMAND).toContain("timeout_s=30");
    expect(bake.APT_UPDATE_COMMAND).toContain("sleep 5");
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

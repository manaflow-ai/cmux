import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import {
  CMUX_CLOUD_LAYOUT,
  cmuxTuiDaemonCommand,
  cmuxTuiInstallCommand,
  cmuxTuiPinCheckCommand,
  cmuxTuiManifestUrl,
  cmuxTuiPersistentMountWait,
  parseCmuxTuiManifest,
  parseEnrollmentInvitationUri,
} from "../services/vms/drivers/cmuxTuiDaemon";

const SHA = "c7a3155341a85a2f10a873d69a041bdf1855ec059a802e58e0779a7a6bdec607";
const COMMIT = "5a4780614cecd8e8ef040a24478f928ef31cc4ae";
const MANIFEST = `https://files.cmux.com/cmux-tui/${COMMIT}/manifest.json`;
const URL = `https://files.cmux.com/cmux-tui/${COMMIT}/cmux-tui-x86_64-unknown-linux-musl`;

function withEnv(values: Record<string, string | undefined>, run: () => void) {
  const previous: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(values)) {
    previous[key] = process.env[key];
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  try {
    run();
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

describe("cmux-tui daemon source", () => {
  test("follows the rolling latest manifest unless a deployment pins one", () => {
    withEnv({ CMUX_VM_CMUX_TUI_MANIFEST_URL: undefined }, () =>
      expect(cmuxTuiManifestUrl()).toBe("https://files.cmux.com/cmux-tui/latest/manifest.json"));
    withEnv({ CMUX_VM_CMUX_TUI_MANIFEST_URL: MANIFEST }, () => expect(cmuxTuiManifestUrl()).toBe(MANIFEST));
    withEnv({ CMUX_VM_CMUX_TUI_MANIFEST_URL: "http://files.cmux.com/x/manifest.json" }, () =>
      expect(() => cmuxTuiManifestUrl()).toThrow(/https/));
  });

  test("takes the linux musl build and its sha256 from the manifest", () => {
    const source = parseCmuxTuiManifest(MANIFEST, {
      commit: COMMIT,
      builtAt: "2026-08-19T07:05:35Z",
      binaries: { "cmux-tui-aarch64-apple-darwin": "a".repeat(64), "cmux-tui-x86_64-unknown-linux-musl": SHA.toUpperCase() },
    });
    expect(source).toEqual({ url: URL, sha256: SHA, commit: COMMIT, builtAt: "2026-08-19T07:05:35Z" });
  });

  test("fails closed on a manifest without a commit or without the musl build", () => {
    expect(() => parseCmuxTuiManifest(MANIFEST, { binaries: { "cmux-tui-x86_64-unknown-linux-musl": SHA } })).toThrow(/commit/);
    expect(() => parseCmuxTuiManifest(MANIFEST, { commit: COMMIT, binaries: { "cmux-tui-x86_64-unknown-linux-gnu": SHA } })).toThrow(/musl/);
    expect(() => parseCmuxTuiManifest(MANIFEST, "nonsense")).toThrow();
  });
});

describe("cmux-tui install and daemon commands", () => {
  test("installs onto the persistent volume, verifies the pin before and after download, and probes the binary", () => {
    const command = cmuxTuiInstallCommand({ url: URL, sha256: SHA, commit: COMMIT, builtAt: null });
    expect(command).toContain("mkdir -p '/root/.cmux/bin'");
    // Skip the download when the installed copy already matches the pin.
    expect(command).toContain(`'${SHA}' '/root/.cmux/bin/cmux-tui' | sha256sum -c >/dev/null 2>&1; then :; else`);
    // The download is verified against the same pin before it replaces anything.
    // A stock base image has no curl yet: install it, else fall back to busybox wget.
    expect(command).toContain("command -v curl >/dev/null 2>&1 || apk add --no-cache curl");
    expect(command).toContain(`curl -fsSL --retry 3 --retry-delay 2 -o '/root/.cmux/bin/cmux-tui.tmp' '${URL}'`);
    expect(command).toContain(`else wget -q -O '/root/.cmux/bin/cmux-tui.tmp' '${URL}'; fi`);
    expect(command).toContain(`'${SHA}' '/root/.cmux/bin/cmux-tui.tmp' | sha256sum -c >/dev/null 2>&1 && chmod 755`);
    expect(command).toContain("ln -sfn '/root/.cmux/bin/cmux-tui' /usr/local/bin/cmux-tui");
    expect(command.endsWith("'/root/.cmux/bin/cmux-tui' --version")).toBe(true);
  });

  // Regression: `sha256sum -c -s` is BusyBox-only. GNU coreutils (the xfce-vnc desktop
  // image) rejects `-s` ("invalid option -- 's'"), which failed every create with a 502.
  test("the pin check never uses the BusyBox-only sha256sum -s flag", () => {
    const command = cmuxTuiInstallCommand({ url: URL, sha256: SHA, commit: COMMIT, builtAt: null });
    expect(command).not.toMatch(/sha256sum[^|&;]*\s-s\b/);
    expect(command).not.toContain("--status");
    expect(command).toContain("sha256sum -c >/dev/null 2>&1");
  });

  test("the daemon serves /v1/link on its own port from the persistent home", () => {
    const command = cmuxTuiDaemonCommand();
    expect(command.startsWith("cd /root && env HOME=/root")).toBe(true);
    expect(command).toContain("server start --session cloud --remote-ws 0.0.0.0:1337 --remote-ws-insecure-bind");
  });

  test("with the cloud layout the install lands in the cmux home and hands the bin dir to the user", () => {
    const command = cmuxTuiInstallCommand({ url: URL, sha256: SHA, commit: COMMIT, builtAt: null }, CMUX_CLOUD_LAYOUT);
    expect(command).toContain("elif mountpoint -q '/cmux/home'");
    expect(command).toContain('CMUX_TUI_BIN="$CMUX_TUI_HOME/.cmux/bin/cmux-tui"');
    expect(command).toContain(`'${SHA}' \"$CMUX_TUI_BIN\" | sha256sum -c >/dev/null 2>&1; then :; else`);
    expect(command).toContain('ln -sfn "$CMUX_TUI_BIN" /usr/local/bin/cmux-tui');
    expect(command).toContain('chown cmux:cmux "$CMUX_TUI_HOME/.cmux" "$CMUX_TUI_HOME/.cmux/bin" "$CMUX_TUI_BIN"');
    expect(command).not.toContain("chown -R");
    expect(command).toContain("if command -v curl >/dev/null 2>&1; then curl -fsSL");
    expect(command).toContain("elif command -v wget >/dev/null 2>&1; then wget -q");
    expect(command).not.toContain("apk add --no-cache curl");
    expect(command).toContain('"$CMUX_TUI_BIN" --version');
    expect(command).toContain("CMUX_TUI_HOME='/home/cmux'");
  });

  test("with the cloud layout the daemon drops to the cmux user, never for pre-layout volumes", () => {
    const command = cmuxTuiDaemonCommand(undefined, CMUX_CLOUD_LAYOUT);
    // Terminals must be non-root shells: agents refuse root
    // (`claude --dangerously-skip-permissions`), sudo is the escalation path.
    expect(command).toContain(
      "runuser -u cmux -- env HOME=/home/cmux USER=cmux LOGNAME=cmux SHELL=/bin/bash TERM=xterm-256color /home/cmux/.cmux/bin/cmux-tui server start",
    );
    expect(command).toContain("&& runuser -u cmux -- test -w /home/cmux 2>/dev/null; then cmux_tui_view_lost=0;");
    expect(command).toContain("cd /home/cmux 2>/dev/null || exit 75; exec runuser -u cmux -- env HOME=/home/cmux");
    expect(command).toContain("runuser -u cmux -- env HOME=/home/cmux");
    expect(command).toContain("cmux_tui_backing_expected=0");
    expect(command).toContain("if mountpoint -q /cmux/home 2>/dev/null; then cmux_tui_backing_expected=1; fi");
    expect(command).toContain("findmnt --poll=umount,move,remount --first-only");
    expect(command).toContain("--mountpoint /home/cmux");
    expect(command).toContain("--mountpoint /cmux/home");
    expect(command).toContain("kill -USR1");
    expect(command).toContain("exit 75");
    expect(command).toContain("printf 'user\\n' > /etc/cmux/daemon-layout");
    expect(command).toContain("printf 'root\\n' > /etc/cmux/daemon-layout");
    // A sandbox born before the layout change still has its persistent volume (data
    // AND daemon state) at /root; it must keep the root daemon until resurrection.
    expect(command).toContain("if mountpoint -q /root 2>/dev/null; then { mkdir -p /etc/cmux 2>/dev/null; printf 'root\\n'");
    expect(command).toContain("exec env HOME=/root TERM=xterm-256color /home/cmux/.cmux/bin/cmux-tui server start");
    expect(command).toContain("exec env HOME=/root TERM=xterm-256color /root/.cmux/bin/cmux-tui server start");
    // Volume mounted but the identity view missing (bindfs failed): home on the
    // persistent backing path as root, never the writable-but-disposable rootfs dir.
    expect(command).toContain("elif mountpoint -q /cmux/home 2>/dev/null && ! mountpoint -q /home/cmux 2>/dev/null; then ");
    expect(command).toContain("cd /cmux/home 2>/dev/null || exit 75; if [ -x /cmux/home/.cmux/bin/cmux-tui ]; then exec env HOME=/cmux/home TERM=xterm-256color /cmux/home/.cmux/bin/cmux-tui server start");
    expect(command).toContain("elif [ -x /root/.cmux/bin/cmux-tui ]; then exec env HOME=/cmux/home TERM=xterm-256color /root/.cmux/bin/cmux-tui server start");
    // No user, no runuser, or an unusable home (bindfs view missing over the
    // root-squashing volume): fall back to root instead of crash-looping.
    expect(command).toContain(
      "[ \"$(id -u cmux 2>/dev/null || echo -1)\" = \"1001\" ] && command -v bash >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && runuser -u cmux -- test -w /home/cmux 2>/dev/null",
    );
    expect(command).toContain("(! mountpoint -q /cmux/home 2>/dev/null || mountpoint -q /home/cmux 2>/dev/null)");
    expect(command).toContain("cd /home/cmux && exec env HOME=/home/cmux TERM=xterm-256color /home/cmux/.cmux/bin/cmux-tui server start");
    // If the work user is unavailable even after setup, keep root fallback state on
    // the mounted volume instead of the disposable /home/cmux rootfs directory.
    expect(command).toContain(
      "if ! mountpoint -q /cmux/home 2>/dev/null; then exit 75; fi; cd /cmux/home 2>/dev/null || exit 75; if [ -x /cmux/home/.cmux/bin/cmux-tui ]; then exec env HOME=/cmux/home",
    );
    // Both root fallbacks leave a breadcrumb so the degraded state is findable.
    expect(command.split("/etc/cmux/root-session-fallback").length - 1).toBe(2);
  });

  test("a volume-backed daemon fails closed while its persistent mount is absent", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-volume-missing-"));
    const fakeBin = join(root, "fake-bin");
    mkdirSync(fakeBin, { recursive: true });
    const writeExecutable = (name: string, contents: string) => {
      const file = join(fakeBin, name);
      writeFileSync(file, contents);
      chmodSync(file, 0o755);
    };
    writeExecutable("mountpoint", "#!/bin/sh\nexit 1\n");
    // Make the failure deterministic even on a host that happens to have findmnt.
    writeExecutable("findmnt", "#!/bin/sh\nexit 1\n");
    const layout = { user: "cmux", home: join(root, "home"), volumeBackingPath: join(root, "backing") } as const;
    const command = cmuxTuiDaemonCommand(undefined, layout, { persistentVolumeExpected: true });
    let child: ReturnType<typeof spawn> | undefined;
    try {
      child = spawn("/bin/sh", ["-c", command], {
        env: { ...process.env, PATH: [fakeBin, process.env.PATH || ""].join(":"), HOME: root },
        stdio: "ignore",
      });
      const exitCode = await new Promise<number>((resolve, reject) => {
        const timer = setTimeout(() => {
          child?.kill("SIGKILL");
          reject(new Error("missing-volume guard timed out"));
        }, 2_000);
        child?.once("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child?.once("exit", (code) => {
          clearTimeout(timer);
          resolve(code ?? -1);
        });
      });
      expect(exitCode).toBe(75);
    } finally {
      child?.kill("SIGKILL");
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("does not wait forever for a late persistent mount", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-mount-timeout-"));
    const fakeBin = join(root, "fake-bin");
    mkdirSync(fakeBin, { recursive: true });
    const writeExecutable = (name: string, contents: string) => {
      const file = join(fakeBin, name);
      writeFileSync(file, contents);
      chmodSync(file, 0o755);
    };
    writeExecutable("mountpoint", "#!/bin/sh\nexit 1\n");
    // An implementation that omits findmnt's timeout hangs forever here. The
    // bounded implementation receives the timeout option and exits through
    // the daemon's restartable failure path.
    writeExecutable("findmnt", [
      "#!/bin/sh",
      "case \"$1\" in",
      "  --help) printf '%s\\n' '--poll --timeout'; exit 0 ;;",
      "  --poll=*)",
      "    has_timeout=0",
      "    for argument in \"$@\"; do case \"$argument\" in --timeout=*) has_timeout=1 ;; esac; done",
      "    if [ \"$has_timeout\" -eq 1 ]; then sleep 0.05; exit 1; fi",
      "    while :; do sleep 1; done",
      "    ;;",
      "esac",
      "exit 1",
      "",
    ].join("\n"));
    const layout = {
      user: "cmux",
      home: join(root, "home"),
      volumeBackingPath: join(root, "backing"),
    } as const;
    const command = cmuxTuiDaemonCommand(undefined, layout, { persistentVolumeExpected: true });
    let child: ReturnType<typeof spawn> | undefined;
    try {
      child = spawn("/bin/sh", ["-c", command], {
        env: { ...process.env, PATH: [fakeBin, process.env.PATH || ""].join(":") },
        stdio: "ignore",
      });
      const exitCode = await new Promise<number>((resolve, reject) => {
        const timer = setTimeout(() => {
          child?.kill("SIGKILL");
          reject(new Error("persistent mount wait timed out"));
        }, 2_000);
        child?.once("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child?.once("exit", (code) => {
          clearTimeout(timer);
          resolve(code ?? -1);
        });
      });
      expect(exitCode).toBe(75);
    } finally {
      child?.kill("SIGKILL");
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("accepts a mount that arrives during the poll handoff", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-mount-handoff-"));
    const fakeBin = join(root, "fake-bin");
    const backing = join(root, "backing");
    const state = join(root, "state");
    mkdirSync(fakeBin, { recursive: true });
    mkdirSync(state, { recursive: true });
    const writeExecutable = (name: string, contents: string) => {
      const file = join(fakeBin, name);
      writeFileSync(file, contents);
      chmodSync(file, 0o755);
    };
    writeExecutable("mountpoint", [
      "#!/bin/sh",
      "path=\"$2\"",
      "if [ \"$path\" = \"$CMUX_TEST_BACKING\" ] && [ -e \"$CMUX_TEST_STATE/mounted\" ]; then exit 0; fi",
      "exit 1",
      "",
    ].join("\n"));
    writeExecutable("findmnt", [
      "#!/bin/sh",
      "case \"$1\" in",
      "  --help) printf '%s\\n' '--poll --timeout'; exit 0 ;;",
      "  --poll=*) : > \"$CMUX_TEST_STATE/mounted\"; exit 1 ;;",
      "esac",
      "exit 1",
      "",
    ].join("\n"));
    const layout = { user: "cmux", home: join(root, "home"), volumeBackingPath: backing } as const;
    const command = `${cmuxTuiPersistentMountWait(layout, true)} printf ready`;
    let child: ReturnType<typeof spawn> | undefined;
    try {
      child = spawn("/bin/sh", ["-c", command], {
        env: {
          ...process.env,
          PATH: [fakeBin, process.env.PATH || ""].join(":"),
          CMUX_TEST_BACKING: backing,
          CMUX_TEST_STATE: state,
        },
        stdio: ["ignore", "pipe", "ignore"],
      });
      const result = await new Promise<{ code: number; stdout: string }>((resolve, reject) => {
        const timer = setTimeout(() => {
          child?.kill("SIGKILL");
          reject(new Error("mount handoff test timed out"));
        }, 2_000);
        let stdout = "";
        child?.stdout?.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
        child?.once("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child?.once("exit", (code) => {
          clearTimeout(timer);
          resolve({ code: code ?? -1, stdout });
        });
      });
      expect(result).toEqual({ code: 0, stdout: "ready" });
    } finally {
      child?.kill("SIGKILL");
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("fails closed when the mount poller returns an error", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-poll-failure-"));
    const fakeBin = join(root, "fake-bin");
    const home = join(root, "home");
    const backing = join(root, "backing");
    const state = join(root, "state");
    mkdirSync(fakeBin, { recursive: true });
    mkdirSync(join(home, ".cmux", "bin"), { recursive: true });
    mkdirSync(backing, { recursive: true });
    mkdirSync(state, { recursive: true });
    const writeExecutable = (name: string, contents: string) => {
      const file = join(fakeBin, name);
      writeFileSync(file, contents);
      chmodSync(file, 0o755);
    };
    writeExecutable("mountpoint", [
      "#!/bin/sh",
      "path=\"$2\"",
      "if [ \"$path\" = \"$CMUX_TEST_BACKING\" ] || [ \"$path\" = \"$CMUX_TEST_HOME\" ]; then exit 0; fi",
      "exit 1",
      "",
    ].join("\n"));
    // A supported findmnt that fails at runtime must restart the supervisor,
    // not make its polling loop consume a CPU indefinitely.
    writeExecutable("findmnt", [
      "#!/bin/sh",
      "case \"$1\" in",
      "  --help) printf '%s\\n' '--poll'; exit 0 ;;",
      "  --poll=*) while [ ! -e \"$CMUX_TEST_STATE/daemon-ready\" ]; do sleep 0.01; done; exit 1 ;;",
      "esac",
      "exit 1",
      "",
    ].join("\n"));
    writeExecutable("id", [
      "#!/bin/sh",
      "if [ \"$1\" = \"-u\" ] && [ \"$2\" = \"cmux\" ]; then printf '1001\\n'; exit 0; fi",
      "exit 1",
      "",
    ].join("\n"));
    writeExecutable("sudo", "#!/bin/sh\nexit 0\n");
    writeExecutable("runuser", [
      "#!/bin/sh",
      "while [ \"$#\" -gt 0 ] && [ \"$1\" != \"--\" ]; do shift; done",
      "[ \"$#\" -gt 0 ] && shift",
      "[ \"$1\" = \"env\" ] && shift",
      "while [ \"$#\" -gt 0 ]; do",
      "  case \"$1\" in *=*) export \"$1\"; shift ;; *) break ;; esac",
      "done",
      "exec \"$@\"",
      "",
    ].join("\n"));
    const daemonBinary = join(home, ".cmux", "bin", "cmux-tui");
    writeFileSync(daemonBinary, [
      "#!/bin/sh",
      "trap ': > \"$CMUX_TEST_STATE/daemon-term\"; exit 0' TERM INT HUP",
      ": > \"$CMUX_TEST_STATE/daemon-ready\"",
      "while :; do :; done",
      "",
    ].join("\n"));
    chmodSync(daemonBinary, 0o755);
    const layout = { user: "cmux", home, volumeBackingPath: backing } as const;
    const command = cmuxTuiDaemonCommand(undefined, layout, { persistentVolumeExpected: true });
    let child: ReturnType<typeof spawn> | undefined;
    try {
      child = spawn("/bin/sh", ["-c", command], {
        env: {
          ...process.env,
          PATH: [fakeBin, process.env.PATH || ""].join(":"),
          CMUX_TEST_HOME: home,
          CMUX_TEST_BACKING: backing,
          CMUX_TEST_STATE: state,
        },
        stdio: "ignore",
      });
      const exitCode = await new Promise<number>((resolve, reject) => {
        const timer = setTimeout(() => {
          child?.kill("SIGKILL");
          reject(new Error("findmnt failure supervisor test timed out"));
        }, 2_000);
        child?.once("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child?.once("exit", (code) => {
          clearTimeout(timer);
          resolve(code ?? -1);
        });
      });
      expect(exitCode).toBe(75);
      expect(existsSync(join(state, "daemon-ready"))).toBe(true);
      expect(existsSync(join(state, "daemon-term"))).toBe(true);
    } finally {
      child?.kill("SIGKILL");
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("selects the persistent binary for layout installs", () => {
    const command = cmuxTuiInstallCommand(
      { url: URL, sha256: SHA, commit: COMMIT, builtAt: null },
      CMUX_CLOUD_LAYOUT,
    );
    expect(command).toContain("mountpoint -q '/cmux/home'");
    expect(command).toContain("CMUX_TUI_HOME='/cmux/home'");
    expect(command).toContain('CMUX_TUI_BIN=\"$CMUX_TUI_HOME/.cmux/bin/cmux-tui\"');
    expect(command).toContain('CMUX_TUI_TMP=\"$CMUX_TUI_BIN.tmp\"');
  });

  test("restarts away from a lost bindfs view instead of keeping the disposable home", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-view-"));
    const fakeBin = join(root, "fake-bin");
    const home = join(root, "home");
    const backing = join(root, "backing");
    const state = join(root, "state");
    mkdirSync(fakeBin, { recursive: true });
    mkdirSync(join(home, ".cmux", "bin"), { recursive: true });
    mkdirSync(backing, { recursive: true });
    mkdirSync(state, { recursive: true });
    const writeExecutable = (name: string, contents: string) => {
      const file = join(fakeBin, name);
      writeFileSync(file, contents);
      chmodSync(file, 0o755);
    };
    writeExecutable("mountpoint", [
      "#!/bin/sh",
      "path=\"$2\"",
      "if [ \"$path\" = \"$CMUX_TEST_BACKING\" ]; then exit 0; fi",
      "if [ \"$path\" = \"$CMUX_TEST_HOME\" ]; then [ ! -e \"$CMUX_TEST_STATE/view-unmounted\" ]; exit $?; fi",
      "exit 1",
      "",
    ].join("\n"));
    writeExecutable("findmnt", [
      "#!/bin/sh",
      "case \"$1\" in",
      "  --help) printf '%s\\n' '--poll'; exit 0 ;;",
      "  --poll=*) while [ ! -e \"$CMUX_TEST_STATE/daemon-ready\" ]; do sleep 0.01; done; : > \"$CMUX_TEST_STATE/view-unmounted\"; exit 0 ;;",
      "esac",
      "exit 1",
      "",
    ].join("\n"));
    writeExecutable("id", [
      "#!/bin/sh",
      "if [ \"$1\" = \"-u\" ] && [ \"$2\" = \"cmux\" ]; then printf '1001\\n'; exit 0; fi",
      "exit 1",
      "",
    ].join("\n"));
    writeExecutable("sudo", "#!/bin/sh\nexit 0\n");
    writeExecutable("runuser", [
      "#!/bin/sh",
      "while [ \"$#\" -gt 0 ] && [ \"$1\" != \"--\" ]; do shift; done",
      "[ \"$#\" -gt 0 ] && shift",
      "[ \"$1\" = \"env\" ] && shift",
      "while [ \"$#\" -gt 0 ]; do",
      "  case \"$1\" in *=*) export \"$1\"; shift ;; *) break ;; esac",
      "done",
      "exec \"$@\"",
      "",
    ].join("\n"));
    const daemonBinary = join(home, ".cmux", "bin", "cmux-tui");
    writeFileSync(daemonBinary, [
      "#!/bin/sh",
      "trap ': > \"$CMUX_TEST_STATE/daemon-term\"; exit 0' TERM INT HUP",
      ": > \"$CMUX_TEST_STATE/daemon-ready\"",
      // Keep the fake daemon in shell code so its TERM trap runs reliably when
      // the supervisor switches away from the lost view.
      "while :; do :; done",
      "",
    ].join("\n"));
    chmodSync(daemonBinary, 0o755);
    const layout = { user: "cmux", home, volumeBackingPath: backing } as const;
    const command = cmuxTuiDaemonCommand(undefined, layout);
    let child: ReturnType<typeof spawn> | undefined;
    try {
      child = spawn("/bin/sh", ["-c", command], {
        env: {
          ...process.env,
          PATH: [fakeBin, process.env.PATH || ""].join(":"),
          CMUX_TEST_HOME: home,
          CMUX_TEST_BACKING: backing,
          CMUX_TEST_STATE: state,
        },
        stdio: "ignore",
      });
      const exitCode = await new Promise<number>((resolve, reject) => {
        const timer = setTimeout(() => {
          child?.kill("SIGKILL");
          reject(new Error("mount-loss supervisor test timed out"));
        }, 5_000);
        child?.once("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child?.once("exit", (code) => {
          clearTimeout(timer);
          resolve(code ?? -1);
        });
      });
      expect(exitCode).toBe(75);
      expect(existsSync(join(state, "daemon-ready"))).toBe(true);
      expect(existsSync(join(state, "daemon-term"))).toBe(true);
    } finally {
      child?.kill("SIGKILL");
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("force-stops a daemon that ignores TERM after mount loss", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-unresponsive-daemon-"));
    const fakeBin = join(root, "fake-bin");
    const backing = join(root, "backing");
    const state = join(root, "state");
    mkdirSync(fakeBin, { recursive: true });
    mkdirSync(join(backing, ".cmux", "bin"), { recursive: true });
    mkdirSync(state, { recursive: true });
    const writeExecutable = (name: string, contents: string) => {
      const file = join(fakeBin, name);
      writeFileSync(file, contents);
      chmodSync(file, 0o755);
    };
    writeExecutable("mountpoint", [
      "#!/bin/sh",
      "path=\"$2\"",
      "if [ \"$path\" = \"$CMUX_TEST_BACKING\" ]; then [ ! -e \"$CMUX_TEST_STATE/backing-unmounted\" ]; exit $?; fi",
      "exit 1",
      "",
    ].join("\n"));
    writeExecutable("findmnt", [
      "#!/bin/sh",
      "case \"$1\" in",
      "  --help) printf '%s\\n' '--poll'; exit 0 ;;",
      "  --poll=*) while [ ! -e \"$CMUX_TEST_STATE/daemon-ready\" ]; do sleep 0.01; done; : > \"$CMUX_TEST_STATE/backing-unmounted\"; exit 0 ;;",
      "esac",
      "exit 1",
      "",
    ].join("\n"));
    const daemonBinary = join(backing, ".cmux", "bin", "cmux-tui");
    writeFileSync(daemonBinary, [
      "#!/bin/sh",
      "trap ':' TERM INT HUP",
      ": > \"$CMUX_TEST_STATE/daemon-ready\"",
      "while :; do :; done",
      "",
    ].join("\n"));
    chmodSync(daemonBinary, 0o755);
    const layout = { user: "cmux", home: join(root, "home"), volumeBackingPath: backing } as const;
    const command = cmuxTuiDaemonCommand(undefined, layout);
    let child: ReturnType<typeof spawn> | undefined;
    try {
      child = spawn("/bin/sh", ["-c", command], {
        env: {
          ...process.env,
          PATH: [fakeBin, process.env.PATH || ""].join(":"),
          CMUX_TEST_BACKING: backing,
          CMUX_TEST_STATE: state,
        },
        stdio: "ignore",
      });
      const exitCode = await new Promise<number>((resolve, reject) => {
        const timer = setTimeout(() => {
          child?.kill("SIGKILL");
          reject(new Error("unresponsive daemon shutdown timed out"));
        }, 5_000);
        child?.once("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child?.once("exit", (code) => {
          clearTimeout(timer);
          resolve(code ?? -1);
        });
      });
      expect(exitCode).toBe(75);
      expect(existsSync(join(state, "daemon-ready"))).toBe(true);
    } finally {
      child?.kill("SIGKILL");
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("supervises the root fallback while its backing mount is present", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-backing-"));
    const fakeBin = join(root, "fake-bin");
    const home = join(root, "home");
    const backing = join(root, "backing");
    const state = join(root, "state");
    mkdirSync(fakeBin, { recursive: true });
    mkdirSync(join(backing, ".cmux", "bin"), { recursive: true });
    mkdirSync(state, { recursive: true });
    const writeExecutable = (name: string, contents: string) => {
      const file = join(fakeBin, name);
      writeFileSync(file, contents);
      chmodSync(file, 0o755);
    };
    writeExecutable("mountpoint", [
      "#!/bin/sh",
      "path=\"$2\"",
      "if [ \"$path\" = \"$CMUX_TEST_BACKING\" ]; then [ ! -e \"$CMUX_TEST_STATE/backing-unmounted\" ]; exit $?; fi",
      "exit 1",
      "",
    ].join("\n"));
    writeExecutable("findmnt", [
      "#!/bin/sh",
      "case \"$1\" in",
      "  --help) printf '%s\\n' '--poll'; exit 0 ;;",
      "  --poll=*) while [ ! -e \"$CMUX_TEST_STATE/daemon-ready\" ]; do sleep 0.01; done; : > \"$CMUX_TEST_STATE/backing-unmounted\"; exit 0 ;;",
      "esac",
      "exit 1",
      "",
    ].join("\n"));
    const daemonBinary = join(backing, ".cmux", "bin", "cmux-tui");
    writeFileSync(daemonBinary, [
      "#!/bin/sh",
      "trap ': > \"$CMUX_TEST_STATE/daemon-term\"; exit 0' TERM INT HUP",
      ": > \"$CMUX_TEST_STATE/daemon-ready\"",
      "while :; do :; done",
      "",
    ].join("\n"));
    chmodSync(daemonBinary, 0o755);
    const layout = { user: "cmux", home, volumeBackingPath: backing } as const;
    const command = cmuxTuiDaemonCommand(undefined, layout);
    let child: ReturnType<typeof spawn> | undefined;
    try {
      child = spawn("/bin/sh", ["-c", command], {
        env: {
          ...process.env,
          PATH: [fakeBin, process.env.PATH || ""].join(":"),
          CMUX_TEST_BACKING: backing,
          CMUX_TEST_STATE: state,
        },
        stdio: "ignore",
      });
      const exitCode = await new Promise<number>((resolve, reject) => {
        const timer = setTimeout(() => {
          child?.kill("SIGKILL");
          reject(new Error("backing-loss supervisor test timed out"));
        }, 5_000);
        child?.once("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child?.once("exit", (code) => {
          clearTimeout(timer);
          resolve(code ?? -1);
        });
      });
      expect(exitCode).toBe(75);
      expect(existsSync(join(state, "daemon-ready"))).toBe(true);
      expect(existsSync(join(state, "daemon-term"))).toBe(true);
    } finally {
      child?.kill("SIGKILL");
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("keeps the root fallback alive without findmnt when the backing mount is present", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-backing-no-findmnt-"));
    const fakeBin = join(root, "fake-bin");
    const home = join(root, "home");
    const backing = join(root, "backing");
    const state = join(root, "state");
    mkdirSync(fakeBin, { recursive: true });
    mkdirSync(join(backing, ".cmux", "bin"), { recursive: true });
    mkdirSync(state, { recursive: true });
    const writeExecutable = (name: string, contents: string) => {
      const file = join(fakeBin, name);
      writeFileSync(file, contents);
      chmodSync(file, 0o755);
    };
    writeExecutable("mountpoint", [
      "#!/bin/sh",
      "path=\"$2\"",
      "if [ \"$path\" = \"$CMUX_TEST_BACKING\" ]; then if [ -e \"$CMUX_TEST_STATE/daemon-ready\" ]; then : > \"$CMUX_TEST_STATE/fallback-watch-ready\"; fi; [ ! -e \"$CMUX_TEST_STATE/backing-unmounted\" ]; exit $?; fi",
      "exit 1",
      "",
    ].join("\n"));
    // Simulate an older image where the util-linux mount poller was not repaired.
    writeExecutable("findmnt", "#!/bin/sh\nexit 127\n");
    const daemonBinary = join(backing, ".cmux", "bin", "cmux-tui");
    writeFileSync(daemonBinary, [
      "#!/bin/sh",
      "trap ': > \"$CMUX_TEST_STATE/daemon-term\"; exit 0' TERM INT HUP",
      ": > \"$CMUX_TEST_STATE/daemon-ready\"",
      "while :; do :; done",
      "",
    ].join("\n"));
    chmodSync(daemonBinary, 0o755);
    const layout = { user: "cmux", home, volumeBackingPath: backing } as const;
    const command = cmuxTuiDaemonCommand(undefined, layout);
    let child: ReturnType<typeof spawn> | undefined;
    try {
      child = spawn("/bin/sh", ["-c", command], {
        env: {
          ...process.env,
          PATH: [fakeBin, "/bin", "/usr/bin"].join(":"),
          CMUX_TEST_BACKING: backing,
          CMUX_TEST_STATE: state,
        },
        stdio: "ignore",
      });
      const readyDeadline = Date.now() + 2_000;
      while (!existsSync(join(state, "daemon-ready")) && Date.now() < readyDeadline) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      expect(existsSync(join(state, "daemon-ready"))).toBe(true);
      const watcherDeadline = Date.now() + 2_000;
      while (!existsSync(join(state, "fallback-watch-ready")) && Date.now() < watcherDeadline) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      expect(existsSync(join(state, "fallback-watch-ready"))).toBe(true);
      // Missing findmnt must select a bounded direct mount check, not signal the
      // supervisor before the daemon has a chance to serve the mounted home.
      expect(child.exitCode).toBeNull();
      writeFileSync(join(state, "backing-unmounted"), "");
      const exitCode = await new Promise<number>((resolve, reject) => {
        const timer = setTimeout(() => {
          child?.kill("SIGKILL");
          reject(new Error("no-findmnt fallback supervisor test timed out"));
        }, 3_000);
        child?.once("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child?.once("exit", (code) => {
          clearTimeout(timer);
          resolve(code ?? -1);
        });
      });
      expect(exitCode).toBe(75);
      expect(existsSync(join(state, "daemon-term"))).toBe(true);
    } finally {
      child?.kill("SIGKILL");
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("pins the binary in the same persistent location used by layout installs", () => {
    const command = cmuxTuiPinCheckCommand(
      { url: URL, sha256: SHA, commit: COMMIT, builtAt: null },
      CMUX_CLOUD_LAYOUT,
    );
    expect(command).toContain("elif mountpoint -q '/cmux/home'");
    expect(command).toContain('CMUX_TUI_BIN="$CMUX_TUI_HOME/.cmux/bin/cmux-tui"');
    expect(command).toContain('test -x "$CMUX_TUI_BIN"');
  });
});

describe("enrollment invitation parsing", () => {
  test("extracts the id and expiry the approve flow needs", () => {
    const payload = {
      version: 1,
      id: "inv_abc-123",
      secret: "s3cret",
      daemon_public_key: "pk",
      daemon_fingerprint: "fp-daemon",
      daemon_name: "cloud",
      expires_at_unix: 1_800_000_000,
      route_hints: [],
      relay_access: [],
      approval_required: true,
    };
    const uri = `cmux://enroll/${Buffer.from(JSON.stringify(payload)).toString("base64url")}`;
    expect(parseEnrollmentInvitationUri(uri)).toEqual({
      id: "inv_abc-123",
      expiresAtUnix: 1_800_000_000,
      daemonFingerprint: "fp-daemon",
    });
  });

  test("rejects foreign schemes and malformed payloads", () => {
    expect(() => parseEnrollmentInvitationUri("https://example.com/enroll")).toThrow(/scheme/);
    expect(() => parseEnrollmentInvitationUri("cmux://enroll/!!!")).toThrow(/undecodable|id or expiry/);
    const missing = `cmux://enroll/${Buffer.from(JSON.stringify({ version: 1 })).toString("base64url")}`;
    expect(() => parseEnrollmentInvitationUri(missing)).toThrow(/id or expiry/);
  });
});

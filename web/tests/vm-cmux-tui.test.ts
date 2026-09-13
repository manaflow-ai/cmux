import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import {
  CMUX_TUI_DAEMON_TERMINAL_ENV,
  CMUX_TUI_LAYOUT_MARKER_PATH,
  cmuxTuiDaemonCommand,
  cmuxTuiAgentHooksInstallCommand,
  cmuxTuiAsDaemonUser,
  cmuxTuiHooksReadyCommand,
  cmuxTuiInstallCommand,
  cmuxTuiPinnedManifestUrl,
  cmuxTuiLayoutSelector,
  cmuxTuiPinCheckCommand,
  cmuxTuiManifestUrl,
  cmuxTuiRunCommand,
  parseCmuxTuiManifest,
  cmuxTuiAttachBundleCommand,
  cmuxTuiTrustedListenerProbe,
  parseCmuxTuiAttachBundle,
} from "../services/vms/drivers/cmuxTuiDaemon";

const SHA = "c7a3155341a85a2f10a873d69a041bdf1855ec059a802e58e0779a7a6bdec607";
const COMMIT = "5a4780614cecd8e8ef040a24478f928ef31cc4ae";
const MANIFEST = `https://files.cmux.com/cmux-tui/${COMMIT}/manifest.json`;
const URL = `https://files.cmux.com/cmux-tui/${COMMIT}/cmux-tui-x86_64-unknown-linux-musl`;
const HOOK_SHA = "9f2e4c1a7b3d5e6f0a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5a6b7";
const HOOK_URL = `https://files.cmux.com/cmux-tui/${COMMIT}/cmux-tui-hook-x86_64-unknown-linux-musl`;

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
      binaries: {
        "cmux-tui-aarch64-apple-darwin": "a".repeat(64),
        "cmux-tui-x86_64-unknown-linux-musl": SHA.toUpperCase(),
        "cmux-tui-hook-x86_64-unknown-linux-musl": HOOK_SHA.toUpperCase(),
      },
    });
    // The hook helper comes from the same commit as the daemon: a machine
    // never pairs a daemon with a helper of another generation.
    expect(source).toEqual({ url: URL, sha256: SHA, commit: COMMIT, builtAt: "2026-08-19T07:05:35Z", hookUrl: HOOK_URL, hookSha256: HOOK_SHA });
  });

  test("fails closed on a manifest without a commit, without the musl build, or without the hook helper", () => {
    const both = { "cmux-tui-x86_64-unknown-linux-musl": SHA, "cmux-tui-hook-x86_64-unknown-linux-musl": HOOK_SHA };
    expect(() => parseCmuxTuiManifest(MANIFEST, { binaries: both })).toThrow(/commit/);
    expect(() => parseCmuxTuiManifest(MANIFEST, { commit: COMMIT, binaries: { "cmux-tui-x86_64-unknown-linux-gnu": SHA, "cmux-tui-hook-x86_64-unknown-linux-musl": HOOK_SHA } })).toThrow(/musl/);
    expect(() => parseCmuxTuiManifest(MANIFEST, { commit: COMMIT, binaries: { "cmux-tui-x86_64-unknown-linux-musl": SHA } })).toThrow(/cmux-tui-hook/);
    expect(() => parseCmuxTuiManifest(MANIFEST, "nonsense")).toThrow();
  });

  test("a pinned manifest is the commit's sibling of the rolling pointer", () => {
    expect(cmuxTuiPinnedManifestUrl(COMMIT)).toBe(MANIFEST);
    withEnv({ CMUX_VM_CMUX_TUI_MANIFEST_URL: "https://files.example/tui/deadbeef/manifest.json" }, () =>
      expect(cmuxTuiPinnedManifestUrl(COMMIT)).toBe(`https://files.example/tui/${COMMIT}/manifest.json`));
    expect(() => cmuxTuiPinnedManifestUrl("abc")).toThrow(/full sha/);
  });
});

describe("cmux-tui install and daemon commands", () => {
  test("installs into the daemon's own home, verifies the pin before and after download, and probes the binary", () => {
    const command = cmuxTuiInstallCommand({ url: URL, sha256: SHA, commit: COMMIT, builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64) });
    // One runtime selection, shared with the daemon launch, so install and
    // launch can never disagree about where the binary lives.
    expect(command).toContain(cmuxTuiLayoutSelector());
    expect(command).toContain('mkdir -p "$(dirname "$CMUX_TUI_BIN")"');
    // Skip the download when the installed copy already matches the pin.
    expect(command).toContain(`'${SHA}' "$CMUX_TUI_BIN" | sha256sum -c >/dev/null 2>&1; then :; else`);
    // The download is verified against the same pin before it replaces anything.
    expect(command).toContain(`curl -fsSL --retry 3 --retry-delay 2 -o "$CMUX_TUI_TMP" '${URL}'`);
    expect(command).toContain(`wget -q -O "$CMUX_TUI_TMP" '${URL}'`);
    expect(command).toContain(`'${SHA}' "$CMUX_TUI_TMP" | sha256sum -c >/dev/null 2>&1 && chmod 755`);
    expect(command).toContain('ln -sfn "$CMUX_TUI_BIN" /usr/local/bin/cmux-tui');
    // Only the nodes the install created; never a walk of the state tree.
    expect(command).toContain('chown "$CMUX_TUI_USER:$CMUX_TUI_USER" "$CMUX_TUI_HOME/.cmux" "$CMUX_TUI_HOME/.cmux/bin" "$CMUX_TUI_BIN"');
    expect(command).not.toContain("chown -R");
    expect(command).toContain('"$CMUX_TUI_BIN" --version');
  });

  test("installs the hook helper beside the daemon from the same pin and writes the Claude Code and Codex hooks as the daemon user", () => {
    const source = { url: URL, sha256: SHA, commit: COMMIT, builtAt: null, hookUrl: HOOK_URL, hookSha256: HOOK_SHA };
    const command = cmuxTuiInstallCommand(source);
    // Beside the binary: the one place `agent hook install` finds it without a PATH search.
    expect(command).toContain('CMUX_TUI_HOOK_BIN="$(dirname "$CMUX_TUI_BIN")/cmux-tui-hook"');
    expect(command).toContain(`'${HOOK_SHA}' "$CMUX_TUI_HOOK_BIN" | sha256sum -c >/dev/null 2>&1; then :; else`);
    expect(command).toContain(`curl -fsSL --retry 3 --retry-delay 2 -o "$CMUX_TUI_HOOK_TMP" '${HOOK_URL}'`);
    expect(command).toContain(`'${HOOK_SHA}' "$CMUX_TUI_HOOK_TMP" | sha256sum -c >/dev/null 2>&1 && chmod 755`);
    expect(command).toContain('"$CMUX_TUI_BIN" "$CMUX_TUI_HOOK_BIN" 2>/dev/null || true');
    // The hooks are the daemon user's (HOME=/home/cmux), never root's: root's
    // settings are invisible to the terminals the daemon spawns.
    const install = cmuxTuiAsDaemonUser('"$CMUX_TUI_BIN" agent hook install claude codex >/dev/null');
    expect(command).toContain(install);
    expect(command.indexOf('"$CMUX_TUI_BIN" --version')).toBeLessThan(command.indexOf(install));
    // And proven, not assumed: helper installed and byte-equal to the pin,
    // every provider config carrying the cmux marker, codex trust state written.
    expect(command).toContain('test -x "$CMUX_TUI_HOME/.local/share/cmux-tui/bin/cmux-tui-hook"');
    expect(command).toContain('cmp -s "$CMUX_TUI_HOOK_BIN" "$CMUX_TUI_HOME/.local/share/cmux-tui/bin/cmux-tui-hook"');
    // Structured status, not a text grep: a user-edited entry reports partial and is repaired.
    expect(command).toContain(cmuxTuiAsDaemonUser('"$CMUX_TUI_BIN" --json agent hook status claude codex'));
    expect(command).toContain('all(s.get(i) == "installed" for i in ["claude","codex"])');
    expect(command).not.toContain("grep -q cmux-tui-journal-hook");
  });

  test("the pinned manifest URL keeps the mirror's origin and query and handles a root-level pointer", () => {
    withEnv({ CMUX_VM_CMUX_TUI_MANIFEST_URL: "https://mirror.example/manifest.json?token=abc" }, () =>
      expect(cmuxTuiPinnedManifestUrl(COMMIT)).toBe(`https://mirror.example/${COMMIT}/manifest.json?token=abc`));
    withEnv({ CMUX_VM_CMUX_TUI_MANIFEST_URL: "https://files.example/tui/latest/manifest.json?x=1" }, () =>
      expect(cmuxTuiPinnedManifestUrl(COMMIT)).toBe(`https://files.example/tui/${COMMIT}/manifest.json?x=1`));
    withEnv({ CMUX_VM_CMUX_TUI_MANIFEST_URL: "https://files.example/tui/latest/index.json" }, () =>
      expect(() => cmuxTuiPinnedManifestUrl(COMMIT)).toThrow(/manifest\.json/));
  });

  test("the hooks-only install never touches the daemon binary", () => {
    const source = { url: URL, sha256: SHA, commit: COMMIT, builtAt: null, hookUrl: HOOK_URL, hookSha256: HOOK_SHA };
    const command = cmuxTuiAgentHooksInstallCommand(source);
    expect(command).toContain(cmuxTuiLayoutSelector());
    expect(command).toContain(HOOK_URL);
    expect(command).not.toContain(URL);
    expect(command).not.toContain("ln -sfn");
    expect(command).not.toContain("--version");
    expect(command).toContain("agent hook install claude codex");
    expect(cmuxTuiHooksReadyCommand()).toContain(cmuxTuiLayoutSelector());
    expect(cmuxTuiHooksReadyCommand()).toContain('test -x "$CMUX_TUI_HOME/.local/share/cmux-tui/bin/cmux-tui-hook"');
  });

  // Regression: `sha256sum -c -s` is BusyBox-only. GNU coreutils (the xfce-vnc desktop
  // image) rejects `-s` ("invalid option -- 's'"), which failed every create with a 502.
  test("the pin check never uses the BusyBox-only sha256sum -s flag", () => {
    const command = cmuxTuiInstallCommand({ url: URL, sha256: SHA, commit: COMMIT, builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64) });
    expect(command).not.toMatch(/sha256sum[^|&;]*\s-s\b/);
    expect(command).not.toContain("--status");
    expect(command).toContain("sha256sum -c >/dev/null 2>&1");
  });

  test("the pin check reads the same binary the daemon runs", () => {
    const command = cmuxTuiPinCheckCommand({ url: URL, sha256: SHA, commit: COMMIT, builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64) });
    expect(command).toContain(cmuxTuiLayoutSelector());
    expect(command).toContain('test -x "$CMUX_TUI_BIN"');
    expect(command).toContain(`'${SHA}' "$CMUX_TUI_BIN" | sha256sum -c`);
  });

  test("the daemon drops to the work user and serves /v1/link on its own port", () => {
    const command = cmuxTuiDaemonCommand();
    // Terminals must be non-root shells: agents refuse root
    // (`claude --dangerously-skip-permissions`), sudo is the escalation path.
    expect(command).toContain(cmuxTuiLayoutSelector());
    // setpriv, not runuser or su: it EXECs in place, so the daemon is the
    // direct child of its supervisor. With a wrapper in between, SIGTERM never
    // reached the daemon (it was SIGKILLed, and its next start rejected the
    // half-written shutdown record), and `pgrep -f` matched the wrapper first.
    expect(command).toContain(
      `exec setpriv --reuid="$CMUX_TUI_USER" --regid="$CMUX_TUI_USER" --init-groups env HOME="$CMUX_TUI_HOME" USER="$CMUX_TUI_USER" LOGNAME="$CMUX_TUI_USER" SHELL=/bin/bash ${CMUX_TUI_DAEMON_TERMINAL_ENV} "$CMUX_TUI_BIN"`,
    );
    expect(command).not.toContain("runuser");
    expect(command).toContain('cd "$CMUX_TUI_HOME"');
    expect(command).toContain(`printf '%s\\n' "$CMUX_TUI_LAYOUT" > ${CMUX_TUI_LAYOUT_MARKER_PATH}`);
    expect(command).toContain("server start --session cloud --remote-ws 0.0.0.0:1337 --remote-ws-insecure-bind --remote-ws-trusted-carrier");
  });

  test("driver-side cmux-tui calls read the daemon's own state, not root's", () => {
    const command = cmuxTuiRunCommand("server status --session cloud");
    expect(command).toContain(cmuxTuiLayoutSelector());
    expect(command).toContain('setpriv --reuid="$CMUX_TUI_USER" --regid="$CMUX_TUI_USER" --init-groups env HOME="$CMUX_TUI_HOME"');
    expect(command).toContain('"$CMUX_TUI_BIN" server status --session cloud');
  });

  test("the work user is used only when it can do the job it promises", () => {
    const selector = cmuxTuiLayoutSelector();
    expect(selector).toContain("id -u cmux");
    expect(selector).toContain("command -v setpriv");
    expect(selector).toContain("setpriv --reuid=cmux --regid=cmux --init-groups test -w /home/cmux");
    // Passwordless sudo is part of the promise: a session that cannot escalate
    // is worse than a root session, so a broken sudoers picks the root layout.
    expect(selector).toContain("setpriv --reuid=cmux --regid=cmux --init-groups sudo -n true");
    // No PAM session per probe: the supervisor evaluates this on every restart.
    expect(selector).not.toContain("runuser");
    expect(selector).toContain("CMUX_TUI_USER=root; CMUX_TUI_HOME=/root; CMUX_TUI_LAYOUT=root");
  });

  /** Runs a shell snippet with `bin` first on PATH and returns its stdout. */
  function runWithStubs(snippet: string, stubs: Record<string, string>): string {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-layout-"));
    const fakeBin = join(root, "bin");
    mkdirSync(fakeBin, { recursive: true });
    try {
      for (const [name, body] of Object.entries(stubs)) {
        const file = join(fakeBin, name);
        writeFileSync(file, body);
        chmodSync(file, 0o755);
      }
      const result = spawnSync("/bin/sh", ["-c", snippet], {
        env: { ...process.env, PATH: [fakeBin, "/usr/bin", "/bin"].join(":") },
        encoding: "utf8",
      });
      expect(result.status).toBe(0);
      return (result.stdout ?? "").trim();
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }

  const report = '; printf %s:%s:%s "$CMUX_TUI_USER" "$CMUX_TUI_HOME" "$CMUX_TUI_BIN"';

  test("a machine with a usable work user runs its sessions as that user", () => {
    const out = runWithStubs(`${cmuxTuiLayoutSelector()}${report}`, {
      id: "#!/bin/sh\nexit 0\n",
      setpriv: "#!/bin/sh\nexit 0\n",
      sudo: "#!/bin/sh\nexit 0\n",
    });
    expect(out).toBe("cmux:/home/cmux:/home/cmux/.cmux/bin/cmux-tui");
  });

  test("a machine from a pre-work-user image keeps its root daemon and /root state", () => {
    const out = runWithStubs(`${cmuxTuiLayoutSelector()}${report}`, {
      // No such user: an image baked before the work user existed.
      id: "#!/bin/sh\nexit 1\n",
      setpriv: "#!/bin/sh\nexit 0\n",
    });
    expect(out).toBe("root:/root:/root/.cmux/bin/cmux-tui");
  });

  test("a work user without passwordless sudo falls back to root rather than trapping the session", () => {
    const out = runWithStubs(`${cmuxTuiLayoutSelector()}${report}`, {
      id: "#!/bin/sh\nexit 0\n",
      // the writability probe passes, the `sudo -n true` probe does not.
      setpriv: '#!/bin/sh\ncase "$*" in *sudo*) exit 1;; esac\nexit 0\n',
      sudo: "#!/bin/sh\nexit 0\n",
    });
    expect(out).toBe("root:/root:/root/.cmux/bin/cmux-tui");
  });
});

describe("cmux-tui attach bundle", () => {
  const stdoutFor = (probe: string, devices: string, trusted: string) =>
    ["__CMUX_PROBE__", probe, "__CMUX_DEVICES__", devices, "__CMUX_TRUSTED__", trusted, "__CMUX_END__", ""].join("\n");

  const runBundle = (readyGate: string, deviceFingerprint?: string) => {
    const root = mkdtempSync(join(tmpdir(), "cmux-tui-attach-bundle-"));
    const binary = join(root, "cmux-tui");
    const callsPath = join(root, "calls");
    // The bundle reads the daemon's state, so it runs every call as the
    // daemon's user. This host has no setpriv (and no such user); the stub
    // makes the drop-to-user a pass-through so the rest of the bundle is
    // exercised as written.
    const fakeBin = join(root, "bin");
    mkdirSync(fakeBin, { recursive: true });
    const setpriv = join(fakeBin, "setpriv");
    writeFileSync(setpriv, ["#!/bin/sh", "while [ $# -gt 0 ]; do case \"$1\" in --*) shift;; *) break;; esac; done", 'exec "$@"', ""].join("\n"));
    chmodSync(setpriv, 0o755);
    writeFileSync(binary, [
      "#!/bin/sh",
      "printf '%s\\n' \"$*\" >> \"$CMUX_TEST_CALLS\"",
      "case \"$*\" in",
      `  'remote-probe --json') printf '%s\\n' '{"build_identity":"abc123","remote_protocol":12,"version":"0.13.0"}' ;;`,
      `  'remote enroll devices --session cloud --json') printf '%s\\n' '[{"fingerprint":"fp-1","revoked_at_unix":null}]' ;;`,
      "  *) exit 64 ;;",
      "esac",
      "",
    ].join("\n"));
    chmodSync(binary, 0o755);
    try {
      const result = spawnSync("/bin/sh", ["-c", cmuxTuiAttachBundleCommand({ readyGate, deviceFingerprint, binary })], {
        encoding: "utf8",
        env: {
          ...process.env,
          CMUX_TEST_CALLS: callsPath,
          PATH: [fakeBin, process.env.PATH || ""].join(":"),
        },
        timeout: 5_000,
      });
      expect(result.error).toBeUndefined();
      return {
        status: result.status,
        stdout: result.stdout,
        calls: existsSync(callsPath) ? readFileSync(callsPath, "utf8").trim().split("\n") : [],
      };
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  };

  test("a successful readiness exit reads build, devices, and the trusted probe; nothing is minted", () => {
    const result = runBundle("exit 0", "fp-new");
    expect(result.status).toBe(0);
    expect(result.calls).toEqual([
      "remote-probe --json",
      "remote enroll devices --session cloud --json",
    ]);
    expect(cmuxTuiAttachBundleCommand({})).not.toContain("remote enroll create");
    const bundle = parseCmuxTuiAttachBundle(result.stdout, "freestyle", "vm-1", "fp-new");
    expect(bundle.daemonBuild).toEqual({ commit: "abc123", remoteProtocol: 12, version: "0.13.0" });
    expect(bundle.enrolled).toBe(false);
    // No cloud daemon runs on the test host, so the probe reports untrusted.
    expect(bundle.trustedCarrier).toBe(false);
  });

  test("a failed readiness exit returns the repair signal without calling the daemon", () => {
    const result = runBundle("exit 1");
    expect(result.status).toBe(3);
    expect(result.calls).toEqual([]);
    expect(result.stdout).toBe("");
  });

  test("an enrolled device is recognized so the heal never restarts under it", () => {
    const result = runBundle("exit 0", "fp-1");
    expect(result.status).toBe(0);
    const bundle = parseCmuxTuiAttachBundle(result.stdout, "freestyle", "vm-1", "fp-1");
    expect(bundle.enrolled).toBe(true);
  });

  test("rejects a malformed device fingerprint", () => {
    expect(() => cmuxTuiAttachBundleCommand({ deviceFingerprint: "bad fp; rm -rf /" })).toThrow("unexpected shape");
  });

  test("the trusted probe requires the env or flag on the live daemon and a binary that knows the flag", () => {
    const probe = cmuxTuiTrustedListenerProbe();
    expect(probe).toContain("pgrep -f 'cmux-tui server [s]tart'");
    expect(probe).toContain("/proc/$p/environ");
    expect(probe).toContain("'CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER=1'");
    expect(probe).toContain("/proc/$p/cmdline");
    expect(probe).toContain("'--remote-ws-trusted-carrier'");
    // The running binary answers for itself, so a stale install never reads as
    // trusted: an old parser rejects the flag before it reaches --version.
    expect(probe).toContain("\"/proc/$p/exe\" --remote-ws-trusted-carrier --version >/dev/null 2>&1");
    expect(probe).not.toContain("sha256sum");
  });

  test("parses build, enrollment, and the trusted flag from the fenced output; a missing flag is untrusted", () => {
    const parsed = parseCmuxTuiAttachBundle(
      stdoutFor(
        JSON.stringify({ build_identity: "abc123", remote_protocol: 12, version: "0.13.0" }),
        JSON.stringify([{ fingerprint: "fp-2", revoked_at_unix: null }]),
        "1",
      ),
      "freestyle",
      "vm-1",
      "fp-1",
    );
    expect(parsed.daemonBuild).toEqual({ commit: "abc123", remoteProtocol: 12, version: "0.13.0" });
    expect(parsed.enrolled).toBe(false);
    expect(parsed.trustedCarrier).toBe(true);
    expect(parseCmuxTuiAttachBundle(stdoutFor("{}", "[]", "0"), "freestyle", "vm-1").trustedCarrier).toBe(false);
    expect(parseCmuxTuiAttachBundle(stdoutFor("{}", "[]", ""), "freestyle", "vm-1").trustedCarrier).toBe(false);
    expect(parseCmuxTuiAttachBundle("garbage", "freestyle", "vm-1").trustedCarrier).toBe(false);
  });

  test("an enrolled, unrevoked fingerprint counts; a revoked one does not", () => {
    const enrolled = parseCmuxTuiAttachBundle(
      stdoutFor("{}", JSON.stringify([{ fingerprint: "fp-1", revoked_at_unix: null }]), "1"),
      "freestyle", "vm-1", "fp-1",
    );
    expect(enrolled.enrolled).toBe(true);
    expect(enrolled.daemonBuild).toBeNull();
    const revoked = parseCmuxTuiAttachBundle(
      stdoutFor("{}", JSON.stringify([{ fingerprint: "fp-1", revoked_at_unix: 1 }]), "1"),
      "freestyle", "vm-1", "fp-1",
    );
    expect(revoked.enrolled).toBe(false);
  });
});

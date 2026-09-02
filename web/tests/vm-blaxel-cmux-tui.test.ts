import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  cmuxTuiDaemonCommand,
  cmuxTuiPreviewBranded,
  cmuxTuiInstallCommand,
  cmuxTuiManifestUrl,
  parseCmuxTuiManifest,
  parseEnrollmentInvitationUri,
} from "../services/vms/drivers/blaxel";

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

  test("native relay daemon receives all assigned routes and fetches tickets on demand", () => {
    const command = cmuxTuiDaemonCommand("0.0.0.0:1337", {
      slot: "vm-id",
      ticketUrl: "https://cmux.example/api/internal/vm/id/relay-ticket",
      bootstrapToken: "bootstrap-token",
      routes: [
        { id: "relay-a", route: "relay+wss://relay-a.example/v1/relay", slot: "vm-id" },
        { id: "relay-b", route: "relay+wss://relay-b.example/v1/relay", slot: "vm-id" },
      ],
    });
    expect(command).toContain("cmux-native-relay-daemon");
    // The helper reads route and credential values from the provider env at
    // launch time, so secrets and route values are not embedded in this
    // command string.
    expect(command).toContain("cmux-native-relay-ticket");
    expect(command).not.toContain("bootstrap-token");
    const encodedScripts = [...command.matchAll(/printf '%s' '([^']+)' \| base64 -d/g)].map(
      (match) => Buffer.from(match[1]!, "base64").toString("utf8"),
    );
    const helper = encodedScripts.join("\n");
    expect(helper).toContain("CMUX_NATIVE_RELAY_1_URL");
    expect(helper).toContain("CMUX_NATIVE_RELAY_2_URL");
    expect(helper).not.toContain("--remote-ws");
    expect(helper).toContain('[ "${CMUX_NATIVE_RELAY_ENABLED:-}" = "1" ] || exit 78');
  });

  test("native relay helper does not pass the legacy bind as a cmux-tui argument", () => {
    const command = cmuxTuiDaemonCommand("0.0.0.0:1337", {
      slot: "vm-id",
      ticketUrl: "https://cmux.example/api/internal/vm/id/relay-ticket",
      bootstrapToken: "bootstrap-token",
      routes: [
        { id: "relay-a", route: "relay+wss://relay-a.example/v1/relay", slot: "vm-id" },
        { id: "relay-b", route: "relay+wss://relay-b.example/v1/relay", slot: "vm-id" },
      ],
    });
    const encodedScripts = [...command.matchAll(/printf '%s' '([^']+)' \| base64 -d/g)].map(
      (match) => Buffer.from(match[1]!, "base64").toString("utf8"),
    );
    const daemon = encodedScripts.find((script) => script.includes("set -- server start --session cloud"));
    expect(daemon).toBeDefined();

    const root = mkdtempSync(path.join(tmpdir(), "cmux-native-relay-helper-"));
    try {
      const binary = path.join(root, "cmux-tui");
      const helper = path.join(root, "daemon");
      writeFileSync(binary, '#!/bin/sh\nprintf "%s\\n" "$@"\n');
      chmodSync(binary, 0o755);
      writeFileSync(helper, daemon!.replaceAll("/root/.cmux/bin/cmux-tui", binary));
      chmodSync(helper, 0o755);
      const result = spawnSync("/bin/sh", [helper, "0.0.0.0:1337"], {
        env: {
          ...process.env,
          CMUX_NATIVE_RELAY_ENABLED: "1",
          CMUX_NATIVE_RELAY_TICKET_URL: "https://cmux.example/ticket",
          CMUX_NATIVE_RELAY_BOOTSTRAP_TOKEN: "bootstrap-token",
          CMUX_NATIVE_RELAY_1_URL: "relay+wss://relay-a.example/v1/relay",
          CMUX_NATIVE_RELAY_1_SLOT: "vm-id",
          CMUX_NATIVE_RELAY_1_ID: "relay-a",
          CMUX_NATIVE_RELAY_2_URL: "relay+wss://relay-b.example/v1/relay",
          CMUX_NATIVE_RELAY_2_SLOT: "vm-id",
          CMUX_NATIVE_RELAY_2_ID: "relay-b",
        },
        encoding: "utf8",
      });
      expect(result.status).toBe(0);
      const args = result.stdout.trim().split("\n");
      expect(args.slice(0, 4)).toEqual(["server", "start", "--session", "cloud"]);
      expect(args).not.toContain("0.0.0.0:1337");
      expect(args).toContain("--relay");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
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

describe("daemon preview host selection", () => {
  test("only clients that send a User-Agent get the branded machine host", () => {
    expect(cmuxTuiPreviewBranded(["direct-ws-user-agent"])).toBe(true);
    expect(cmuxTuiPreviewBranded(["something-else", "direct-ws-user-agent"])).toBe(true);
    expect(cmuxTuiPreviewBranded([])).toBe(false);
    expect(cmuxTuiPreviewBranded(undefined)).toBe(false);
  });
});

import { describe, expect, test } from "bun:test";
import {
  cmuxTuiDaemonCommand,
  cmuxTuiInstallCommand,
  parseEnrollmentInvitationUri,
  resolveCmuxTuiSource,
} from "../services/vms/drivers/blaxel";

const SHA = "c7a3155341a85a2f10a873d69a041bdf1855ec059a802e58e0779a7a6bdec607";
const URL = "https://files.cmux.com/cmux-tui/5a4780614cecd8e8ef040a24478f928ef31cc4ae/cmux-tui-x86_64-unknown-linux-musl";

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
  test("is disabled until a deployment opts in with a URL", () => {
    withEnv({ CMUX_VM_BLAXEL_TUI_URL: undefined, CMUX_VM_BLAXEL_TUI_SHA256: undefined }, () => {
      expect(resolveCmuxTuiSource()).toBeNull();
    });
  });

  test("a URL without a sha256 pin fails closed", () => {
    withEnv({ CMUX_VM_BLAXEL_TUI_URL: URL, CMUX_VM_BLAXEL_TUI_SHA256: undefined }, () => {
      expect(() => resolveCmuxTuiSource()).toThrow(/CMUX_VM_BLAXEL_TUI_SHA256/);
    });
    withEnv({ CMUX_VM_BLAXEL_TUI_URL: URL, CMUX_VM_BLAXEL_TUI_SHA256: "nope" }, () => {
      expect(() => resolveCmuxTuiSource()).toThrow(/64 hex/);
    });
  });

  test("requires https so the pin is not the only defense", () => {
    withEnv({ CMUX_VM_BLAXEL_TUI_URL: "http://files.cmux.com/x", CMUX_VM_BLAXEL_TUI_SHA256: SHA }, () => {
      expect(() => resolveCmuxTuiSource()).toThrow(/https/);
    });
  });

  test("resolves a pinned https source, normalizing the pin's case", () => {
    withEnv({ CMUX_VM_BLAXEL_TUI_URL: URL, CMUX_VM_BLAXEL_TUI_SHA256: SHA.toUpperCase() }, () => {
      expect(resolveCmuxTuiSource()).toEqual({ url: URL, sha256: SHA });
    });
  });
});

describe("cmux-tui install and daemon commands", () => {
  test("installs onto the persistent volume, verifies the pin before and after download, and probes the binary", () => {
    const command = cmuxTuiInstallCommand({ url: URL, sha256: SHA });
    expect(command).toContain("mkdir -p '/root/.cmux/bin'");
    // Skip the download when the installed copy already matches the pin.
    expect(command).toContain(`'${SHA}' '/root/.cmux/bin/cmux-tui' | sha256sum -c -s; then :; else`);
    // The download is verified against the same pin before it replaces anything.
    expect(command).toContain(`curl -fsSL --retry 3 --retry-delay 2 -o '/root/.cmux/bin/cmux-tui.tmp' '${URL}'`);
    expect(command).toContain(`'${SHA}' '/root/.cmux/bin/cmux-tui.tmp' | sha256sum -c -s && chmod 755`);
    expect(command).toContain("ln -sfn '/root/.cmux/bin/cmux-tui' /usr/local/bin/cmux-tui");
    expect(command.endsWith("'/root/.cmux/bin/cmux-tui' --version")).toBe(true);
  });

  test("the daemon serves /v1/link on its own port from the persistent home", () => {
    const command = cmuxTuiDaemonCommand();
    expect(command.startsWith("cd /root && env HOME=/root")).toBe(true);
    expect(command).toContain("server start --session cloud --remote-ws 0.0.0.0:1337 --remote-ws-insecure-bind");
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

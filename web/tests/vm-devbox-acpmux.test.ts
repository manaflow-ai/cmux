import { describe, expect, test } from "bun:test";
import {
  CMUX_TUI_ACPMUX_LINUX_TARGET,
  cmuxTuiInstallCommand,
  parseCmuxTuiManifest,
  requireCmuxTuiAcpmux,
} from "../services/vms/drivers/cmuxTuiDaemon";

// Customer Cloud VMs need acpmux in the image (cloud-subagents-DESIGN.md B9): it comes from
// the same attested cmux-tui manifest as the daemon, sha256-pinned, beside the daemon binary
// and on everyone's PATH.
const COMMIT = "4a232fc2c61260dd2a43a941aba12ae4d1b50395";
const MANIFEST = `https://files.cmux.com/cmux-tui/${COMMIT}/manifest.json`;
const SHA = "a".repeat(64);
const HOOK_SHA = "b".repeat(64);
const ACPMUX_SHA = "c".repeat(64);
const binaries = {
  "cmux-tui-x86_64-unknown-linux-musl": SHA,
  "cmux-tui-hook-x86_64-unknown-linux-musl": HOOK_SHA,
};

describe("acpmux in the Cloud image", () => {
  test("the Linux acpmux target is the musl build the artifacts workflow publishes", () => {
    expect(CMUX_TUI_ACPMUX_LINUX_TARGET).toBe("cmux-tui-acpmux-x86_64-unknown-linux-musl");
  });

  test("takes acpmux and its sha256 from the same manifest commit as the daemon", () => {
    const source = parseCmuxTuiManifest("https://files.cmux.com/cmux-tui/latest/manifest.json", {
      commit: COMMIT,
      binaries: { ...binaries, [CMUX_TUI_ACPMUX_LINUX_TARGET]: ACPMUX_SHA.toUpperCase() },
    });
    expect(source.acpmuxUrl).toBe(`https://files.cmux.com/cmux-tui/${COMMIT}/cmux-tui-acpmux-x86_64-unknown-linux-musl`);
    expect(source.acpmuxSha256).toBe(ACPMUX_SHA);
  });

  test("an older manifest without acpmux still parses (servers keep working), but the bake refuses it", () => {
    const source = parseCmuxTuiManifest(MANIFEST, { commit: COMMIT, binaries });
    expect(source.acpmuxUrl).toBeNull();
    expect(source.acpmuxSha256).toBeNull();
    expect(() => requireCmuxTuiAcpmux(source, MANIFEST)).toThrow(/vm_artifact_unavailable/);
    const withAcpmux = parseCmuxTuiManifest(MANIFEST, { commit: COMMIT, binaries: { ...binaries, [CMUX_TUI_ACPMUX_LINUX_TARGET]: ACPMUX_SHA } });
    expect(() => requireCmuxTuiAcpmux(withAcpmux, MANIFEST)).not.toThrow();
  });

  test("the install pins acpmux before and after download, puts it beside the daemon and on PATH, and probes it", () => {
    const source = parseCmuxTuiManifest(MANIFEST, { commit: COMMIT, binaries: { ...binaries, [CMUX_TUI_ACPMUX_LINUX_TARGET]: ACPMUX_SHA } });
    const command = cmuxTuiInstallCommand(source);
    expect(command).toContain('CMUX_TUI_ACPMUX_BIN="$(dirname "$CMUX_TUI_BIN")/acpmux"');
    expect(command).toContain(`'${ACPMUX_SHA}' "$CMUX_TUI_ACPMUX_BIN" | sha256sum -c >/dev/null 2>&1; then :; else`);
    expect(command).toContain(`'${ACPMUX_SHA}' "$CMUX_TUI_ACPMUX_TMP" | sha256sum -c`);
    expect(command).toContain('ln -sfn "$CMUX_TUI_ACPMUX_BIN" /usr/local/bin/acpmux');
    expect(command).toContain('ln -sfn "$CMUX_TUI_ACPMUX_BIN" "$CMUX_TUI_HOME/.local/bin/acpmux"');
    expect(command).toContain('"$CMUX_TUI_ACPMUX_BIN" --version');
    expect(command).toContain(source.acpmuxUrl!);
  });

  test("a source without acpmux installs no acpmux step", () => {
    const command = cmuxTuiInstallCommand(parseCmuxTuiManifest(MANIFEST, { commit: COMMIT, binaries }));
    expect(command).not.toContain("acpmux");
  });
});

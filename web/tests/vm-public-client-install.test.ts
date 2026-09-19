import { expect, test } from "bun:test";
import { cmuxTuiInstallCommand } from "../services/vms/drivers/cmuxTuiDaemon";

const source = {
  url: "https://example.invalid/cmux-tui",
  sha256: "a".repeat(64),
  commit: "fixture",
  builtAt: null,
  hookUrl: "https://example.invalid/cmux-tui-hook",
  hookSha256: "b".repeat(64),
};

test("publishes an executable copy without traversing the daemon's private home", () => {
  const command = cmuxTuiInstallCommand(source);
  expect(command).not.toContain('ln -sfn "$CMUX_TUI_BIN" /usr/local/bin/cmux-tui');
  expect(command).toContain('cmp -s "$CMUX_TUI_BIN"');
  expect(command).toContain('cp "$CMUX_TUI_BIN"');
  expect(command).toContain('chmod 755 "$CMUX_TUI_PUBLIC_TMP"');
  expect(command).toContain('mv -f "$CMUX_TUI_PUBLIC_TMP"');
});

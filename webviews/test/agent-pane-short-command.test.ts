// l10n-allow-file: test fixture commands, not shipped UI.
// A background task's end, when its call is not in the transcript, names the command in a few
// words (conversation/shortCommand.ts): its working step, the program by name, never the raw
// `export PATH=…` line Leo saw (2026-10-20, r2/bottom-notices.png).
import { expect, test } from "bun:test";
import { shortCommand } from "../src/agent-session/acpmux/conversation/shortCommand";

test("setup steps go, the working step stays, its program by name", () => {
  expect(
    shortCommand(
      'export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"; B=~/Projects/leo-workspace/briefs; cmux browser open https://example.com',
    ),
  ).toBe("cmux browser open https://example.com");
  expect(shortCommand("cd ~/src/app && FOO=1 BAR='a b' bun test --watch")).toBe("bun test --watch");
  expect(shortCommand('"/opt/tools/bin/my tool" --flag')).toBe("my tool --flag");
  expect(shortCommand("npm run dev")).toBe("npm run dev");
});

test("steps after the working one leave an ellipsis; a long step is cut", () => {
  expect(shortCommand("cargo build && cargo test")).toBe("cargo build …");
  expect(shortCommand('echo "a; b && c"')).toBe('echo "a; b && c"');
  const long = shortCommand(`pytest ${"tests/unit/test_something_rather_long.py ".repeat(4)}`);
  expect(long.length).toBeLessThanOrEqual(60);
  expect(long.endsWith("…")).toBe(true);
});

test("a command that is all setup keeps its first step, cut to the line", () => {
  const text = shortCommand('export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"; B=~/x');
  expect(text.startsWith("export PATH=")).toBe(true);
  expect(text.length).toBeLessThanOrEqual(60);
  expect(shortCommand("   ")).toBe("");
});

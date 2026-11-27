// l10n-allow-file: test fixture commands, not shipped UI.
// The running tray counts its commands by what they do (trayCommandKinds.ts; Leo, 2026-11-03: "you can split up
// commands/waits/bg tasks/subagents/maybe agent sessions you expect something from ... so you can fit
// that all in counts of stuff and maybe times all in one line like a \ b \ c or a | b| c or a / b /
// c"): each background command's kind comes from its command line.
import { describe, expect, test } from "bun:test";
import { commandKind } from "../src/agent-session/acpmux/subagents/trayCommandKinds";

describe("commandKind", () => {
  const cases: [string, ReturnType<typeof commandKind>][] = [
    ["glaeda-gh wait pr 4210 --sha 1f2e3d4c5b6a", "waits"],
    ["gh run watch 9911223344", "waits"],
    ["gh pr checks 12 --watch", "waits"],
    ["sleep 30 && gh pr view 12", "waits"],
    ["router-review manaflow-ai/app 4210 --post", "reviews"],
    ["sessions new --review --target app:main..HEAD", "reviews"],
    ["cmux-ci test -- bun test test/x.test.ts", "tests"],
    ["cd webviews && bun test test/x.test.ts --timeout 60000", "tests"],
    ["cargo nextest run -p cmux-tui", "tests"],
    ["cmux-ci compile-check --ref abc --app", "builds"],
    ["cargo build --release", "builds"],
    ["cd webviews && bun run build", "builds"],
    ["cd ~/Projects/app && bun run dev", "servers"],
    ['acpmux send review-lane "check it"', "sends"],
    ["tail -f /tmp/app.log", "waits"],
    ["rg -n TODO src", "commands"],
    ["ls -la", "commands"],
  ];
  for (const [line, kind] of cases) test(`${line} → ${kind}`, () => expect(commandKind(line)).toBe(kind));

  test("a word inside another word is not a kind", () => {
    expect(commandKind("cat contest.txt")).toBe("commands");
    expect(commandKind("echo remake")).toBe("commands");
    // A tool named as an argument is not that tool running (review of #34486).
    expect(commandKind("grep -rn tsc webviews/package.json")).toBe("commands");
    expect(commandKind("echo make sense")).toBe("commands");
    expect(commandKind('echo "let go test it"')).toBe("commands");
    expect(commandKind("while read line; do echo $line; done < list")).toBe("commands");
  });

  test("a wrapper or a cd before the tool keeps its kind", () => {
    expect(commandKind("timeout 600 bun test test/x.test.ts")).toBe("tests");
    expect(commandKind("cd webviews && bunx tsc --noEmit")).toBe("builds");
    expect(commandKind("CI=1 cargo test -p cmux-tui")).toBe("tests");
    expect(commandKind("while ! curl -s localhost:3000; do sleep 1; done")).toBe("waits");
  });
});

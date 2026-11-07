// l10n-allow-file: test fixtures (real command lines and the English the rows draw).
// A command row says what its command did (Leo, 2026-11-07: "it's not just you ran a command.
// It's that you ran a specific thing"): a known program and subcommand read as a past-tense verb
// and its main argument, a description names what the table cannot, and anything else reads as
// its command line without the plumbing after it. The full line stays in the opened Shell block.
import { expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { toolLabel } from "../toolPaths";
import { toolGroupLabel } from "./toolGroups";

const t = translatorFor("en");
let next = 0;

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const shell = (command: string, extra: Partial<Tool> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "Bash",
  tool: { id: `cmd-${next++}`, title: "Bash", kind: "execute", status: "completed", command, ...extra },
});

const label = (item: AcpmuxActivity) => {
  const running = item.tool!.status === "in_progress" || item.tool!.status === "pending";
  return toolLabel(
    item.tool!,
    item.text,
    (command) => t(running ? "tools.runningCommand" : "tools.ranCommand", { command }),
    undefined,
    t(running ? "tools.runningUnnamed" : "tools.ranUnnamed"),
  );
};

// Real lines from agent transcripts: Claude's Bash calls and Codex's exec calls.
const CASES: [command: string, label: string][] = [
  // Leo's two rows (2026-11-07 screenshot).
  [
    `agent-memory search "tooltip wrap width leo ask" 2>/dev/null | head -12 | cut -c1-220`,
    "Searched memory for “tooltip wrap width leo ask”",
  ],
  [
    `agent-memory search "better tooltips" 2>/dev/null | head -10 | cut -c1-220`,
    "Searched memory for “better tooltips”",
  ],
  ["git status --short", "Checked git status"],
  ["cd /home/cmux/Projects/checkouts/cmux && git status", "Checked git status"],
  ["git -C ~/Projects/leo-workspace diff --stat origin/main...HEAD", "Viewed the diff"],
  ["git --no-pager log --oneline -5", "Read git history"],
  ["git show 545e4caffe7a --stat | head -60", "Viewed 545e4caffe7a"],
  ["git show origin/feat-cmux-next:webviews/src/agent-session/acpmux/toolPaths.ts | head -50", "Read toolPaths.ts"],
  ["git add -A", "Staged all changes"],
  ["git add webviews/src/a.ts webviews/src/b.ts", "Staged a.ts, b.ts"],
  [`git commit -m "fix: wrap tooltips"`, "Committed “fix: wrap tooltips”"],
  ["git commit --amend --no-edit", "Committed changes"],
  ["git push -u origin HEAD:lane/command-row-labels", "Pushed lane/command-row-labels"],
  ["git push", "Pushed commits"],
  ["git checkout -b lane/x origin/feat-cmux-next", "Created branch lane/x"],
  ["git switch main", "Switched to main"],
  ["git rebase origin/feat-cmux-next", "Rebased onto origin/feat-cmux-next"],
  ["git merge --ff-only origin/main", "Merged origin/main"],
  ["git fetch -q origin feat-cmux-next", "Fetched the latest commits"],
  ["git pull --rebase", "Pulled changes"],
  ["git branch -a", "Listed branches"],
  ["gh pr view 36940 --json body -q .body", "Viewed PR #36940"],
  ["gh pr list -R manaflow-ai/cmux --state open --limit 20", "Listed pull requests"],
  ["gh pr checks 123 -R manaflow-ai/cmux", "Checked CI on PR #123"],
  ["gh pr diff 123 | head -100", "Viewed the diff of PR #123"],
  ["gh pr merge 412 --squash --match-head-commit 0a1b2c", "Merged PR #412"],
  ["gh pr create --base feat-cmux-next --title T --body-file F", "Opened a pull request"],
  ["gh issue view 77 -R manaflow-ai/cmuxterm-hq", "Viewed issue #77"],
  ["gh issue list --label bug", "Listed issues"],
  ["gh run view 4061 --log-failed | tail -50", "Viewed run 4061"],
  ["gh run list --branch main --limit 5", "Listed workflow runs"],
  ["gh api repos/manaflow-ai/cmux/pulls/1 --jq .title", "Called the GitHub API: repos/manaflow-ai/cmux/pulls/1"],
  [`rg -n "toolLabel" webviews/src`, "Searched for “toolLabel”"],
  [`grep -rn "never as" src | grep -v test`, "Searched for “never as”"],
  [`rg -e 'isDraftCall' -g '*.ts' --type ts`, "Searched for “isDraftCall”"],
  ["timeout 20 rg -l shortCommand", "Searched for “shortCommand”"],
  ["ls -la webviews/src", "Listed webviews/src"],
  ["ls", "Listed files"],
  [`find . -name '*.gallery.ts' | wc -l`, "Listed files"],
  // With no root, find lists from where it runs: a predicate is never the folder it lists.
  [`find -name '*.ts'`, "Listed files"],
  ["find -L src -type f", "Listed src"],
  ["fd -e ts toolPaths src", "Listed src"],
  ["cat skills/cmux-localization/SKILL.md", "Read SKILL.md"],
  ["sed -n '380,460p' webviews/src/agent-session/acpmux/conversation/toolGroups.ts", "Read toolGroups.ts"],
  ["head -40 ~/Projects/leo-workspace/tools/agent-memory", "Read agent-memory"],
  ["tail -n 30 /tmp/crl-install.log", "Read crl-install.log"],
  ["cat package.json tsconfig.json", "Read 2 files"],
  ["curl -s 'https://api.example.com/v1/items?page=2' | jq .", "Fetched api.example.com/v1/items"],
  ["bun test src/agent-session/acpmux/conversation/commandLabels.test.ts", "Ran tests in commandLabels.test.ts"],
  ["FOO=1 bun test", "Ran tests with bun"],
  ["cargo test -p acpmux", "Ran tests with cargo"],
  ["env RUST_LOG=debug cargo build --release", "Built with cargo"],
  ["npm install", "Installed packages with npm"],
  ["bun run build", "Built with bun"],
  ["python3 scripts/check_retry.py --fast", "Ran check_retry.py"],
  ["node scripts/pages/gen-strings.mjs", "Ran gen-strings.mjs"],
  ["python3 -m pytest tests/test_x.py -q", "Ran tests with pytest"],
  ["mkdir -p /tmp/out", "Created folder /tmp/out"],
  ["rm -rf build", "Removed build"],
  ["mv a.txt b.txt", "Moved a.txt to b.txt"],
  ["cp -r src dst", "Copied src to dst"],
  ["cmux-ci compile-check --ref 0a1b2c --package CmuxNextIcons", "Ran a compile check"],
  ["cmux-ci test -- bun test src/a.test.ts", "Ran bun test src/a.test.ts on CI"],
  ["lane-gh push manaflow-ai/cmux lane/x --base feat-cmux-next", "Pushed lane/x"],
  ["lane-gh search manaflow-ai/cmux is:pr command label", "Searched GitHub for “is:pr command label”"],
  ["glaeda-gh wait pr manaflow-ai/cmux#123 --until done --timeout 30m", "Waited on manaflow-ai/cmux#123"],
  ["wt new cmux lane/command-row-labels --from origin/feat-cmux-next", "Created worktree lane/command-row-labels"],
  // A compound command names its first step and no more, an ellipsis for the rest.
  ["git add -A && git commit -m wip && git push", "Staged all changes …"],
  // Unknown programs never get a meaning: their line, without the plumbing after it.
  ["make -j8 2>&1 | tail -20", "Ran make -j8"],
  ["./scripts/web-lint.sh > /tmp/lint.log 2>&1", "Ran web-lint.sh"],
  ["pwd && git status --short", "Ran pwd …"],
  ["jq '.strings | length' Localizable.xcstrings", "Ran jq '.strings | length' Localizable.xcstrings"],
  // A subcommand the table does not know reads as its line.
  ["git rev-parse HEAD", "Ran git rev-parse HEAD"],
  ["gh pr view", "Ran gh pr view"],
];

for (const [command, expected] of CASES)
  test(`${command} reads "${expected}"`, () => {
    expect(label(shell(command))).toBe(expected);
  });

test("a description names a command the table does not know, never one it knows", () => {
  const script = `python3 - <<'EOF'\nimport json\nprint(len(json.load(open("a.json"))))\nEOF`;
  expect(label(shell(script, { description: "Count the catalog's keys" }))).toBe("Count the catalog's keys");
  expect(label(shell("git status", { description: "Look around" }))).toBe("Checked git status");
});

test("a running command reads as its cleaned line until it finishes", () => {
  const item = shell(`agent-memory search "better tooltips" 2>/dev/null | head -10`, { status: "in_progress" });
  expect(label(item)).toBe(`Running agent-memory search "better tooltips"`);
});

const commands = (...lines: string[]) => lines.map((line) => shell(line));

// Its launch completed, but it still runs in the background: it has done nothing yet either.
test("a command running in the background reads as its line, alone or in a group", () => {
  expect(label(shell("git status", { background: { state: "running" } }))).toBe("Ran git status");
  const group = commands("git status", "git status");
  group[1]!.tool!.background = { state: "running" };
  expect(toolGroupLabel(t, "commands", group)).not.toBe("Checked git status twice");
});

test("a group of the same search says how many times", () => {
  const leo = commands(
    `agent-memory search "tooltip wrap width leo ask" 2>/dev/null | head -12 | cut -c1-220`,
    `agent-memory search "better tooltips" 2>/dev/null | head -10 | cut -c1-220`,
  );
  expect(toolGroupLabel(t, "commands", leo)).toBe("Searched memory twice");
  expect(toolGroupLabel(t, "commands", [...leo, ...commands(`agent-memory search "hover card"`)])).toBe(
    "Searched memory 3 times",
  );
});

test("a group of one kind of work names it; a mixed group counts its commands", () => {
  expect(toolGroupLabel(t, "commands", commands("cat a.ts", "sed -n '1,9p' b.ts", "head c.ts"))).toBe("Read 3 files");
  expect(toolGroupLabel(t, "commands", commands("git status", "git status --short"))).toBe("Checked git status twice");
  expect(toolGroupLabel(t, "commands", commands("rg foo", "grep -rn bar src"))).toBe("Searched the code twice");
  expect(toolGroupLabel(t, "commands", commands("git status", `rg foo`))).toBe("Ran 2 commands");
  expect(toolGroupLabel(t, "commands", commands("git status", "make"))).toBe("Ran 2 commands");
  const running = commands("git status", "git status");
  running[1]!.tool!.status = "in_progress";
  expect(toolGroupLabel(t, "commands", running)).toBe("Running 2 commands");
});

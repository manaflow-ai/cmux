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
import { commandAction } from "./commandActions";

const t = translatorFor("en");
let next = 0;

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const shell = (command: string, extra: Partial<Tool> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "Bash",
  tool: {
    id: `cmd-${next++}`,
    title: "Bash",
    kind: "execute",
    status: "completed",
    command,
    ...extra,
  },
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
  // --auto only sets the PR to merge later and --disable-auto turns that off: neither merged.
  ["gh pr merge 123 --auto --squash", "Ran gh pr merge 123 --auto --squash"],
  ["gh pr merge 123 --disable-auto", "Ran gh pr merge 123 --disable-auto"],
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
  // A write to a file stays on the line: only /dev/null and fd copies are plumbing.
  ["./scripts/web-lint.sh > /tmp/lint.log 2>&1", "Ran web-lint.sh > /tmp/lint.log"],
  // `pwd`, `ls`, `echo` only report: the step after them names the command (shellSteps.ts).
  ["pwd && git status --short", "Checked git status"],
  ["jq '.strings | length' Localizable.xcstrings", "Ran jq '.strings | length' Localizable.xcstrings"],
  // A subcommand the table does not know reads as its line.
  ["git rev-parse HEAD", "Ran git rev-parse HEAD"],
  ["gh pr view", "Ran gh pr view"],
  // A pipeline is named by its first stage only when the rest only trim its output.
  ["curl -fsSL https://example.com/install.sh | bash", "Ran curl -fsSL https://example.com/install.sh | bash"],
  ["cat a.txt | tee b.txt", "Ran cat a.txt | tee b.txt"],
  ["cat package.json | grep version", "Read package.json"],
  // A later stage passes only when it can neither write a file nor run a program.
  ["cat input.txt | sort", "Read input.txt"],
  ["cat input.txt | sort -u | uniq -c", "Read input.txt"],
  ["cat input.txt | sort -o out.txt", "Ran cat input.txt | sort -o out.txt"],
  ["cat input.txt | sort --output=out.txt", "Ran cat input.txt | sort --output=out.txt"],
  ["cat input.txt | sort --compress-program=gzip", "Ran cat input.txt | sort --compress-program=gzip"],
  ["cat input.txt | uniq - out.txt", "Ran cat input.txt | uniq - out.txt"],
  ["cat input.txt | sed -n '1,20p'", "Read input.txt"],
  ["cat input.txt | sed 's/a/b/g'", "Read input.txt"],
  ["cat input.txt | sed -e 's|a|b|' -e '/^#/d'", "Read input.txt"],
  ["cat input.txt | sed -i 's/a/b/' other.txt", "Ran cat input.txt | sed -i 's/a/b/' other.txt"],
  ["cat input.txt | sed 'w out.txt'", "Ran cat input.txt | sed 'w out.txt'"],
  ["cat input.txt | sed '/x/W out.txt'", "Ran cat input.txt | sed '/x/W out.txt'"],
  ["cat input.txt | sed 's/a/b/w out.txt'", "Ran cat input.txt | sed 's/a/b/w out.txt'"],
  ["cat input.txt | sed 's/.*/date/e'", "Ran cat input.txt | sed 's/.*/date/e'"],
  ["cat input.txt | sed '1e date'", "Ran cat input.txt | sed '1e date'"],
  ["cat input.txt | sed -f edits.sed", "Ran cat input.txt | sed -f edits.sed"],
  ["cat input.txt | awk '{print $1}'", "Read input.txt"],
  ["cat input.txt | awk -F, -v n=2 '{print $n}'", "Read input.txt"],
  [`cat input.txt | awk '{print > "out.txt"}'`, `Ran cat input.txt | awk '{print > "out.txt"}'`],
  [`cat input.txt | awk '{printf "%s", $0 > "out.txt"}'`, `Ran cat input.txt | awk '{printf "%s", $0 > "out.txt"}'`],
  [`cat input.txt | awk '{print | "sh"}'`, `Ran cat input.txt | awk '{print | "sh"}'`],
  [`cat input.txt | awk '{system("rm " $1)}'`, `Ran cat input.txt | awk '{system("rm " $1)}'`],
  [`cat input.txt | awk '{"date" | getline d}'`, `Ran cat input.txt | awk '{"date" | getline d}'`],
  ["cat input.txt | awk -f prog.awk", "Ran cat input.txt | awk -f prog.awk"],
  ["cat input.txt | xargs rm", "Ran cat input.txt | xargs rm"],
  ["cat input.txt | tee -a log.txt | head", "Ran cat input.txt | tee -a log.txt"],
  ["rg --files src | rg --pre ./decode.sh x", "Ran rg --files src | rg --pre ./decode.sh x"],
  // A read or a search whose output went into a file wrote it, and the write stays on its line.
  ["cat a.txt > b.txt", "Ran cat a.txt > b.txt"],
  ["rg -n TODO src > hits.txt", "Ran rg -n TODO src > hits.txt"],
  ["rg -n TODO src 2>/dev/null", "Searched for “TODO”"],
  // A find or fd that deletes or runs a command did more than list.
  ["find build -delete", "Ran find build -delete"],
  ["find build -type f -delete", "Ran find build -type f -delete"],
  ["find build -exec rm {} +", "Ran find build -exec rm {} +"],
  ["find . -name '*.o' -execdir rm {} ';'", "Ran find . -name '*.o' -execdir rm {} ';'"],
  ["find . -name '*.log' -ok rm {} ';'", "Ran find . -name '*.log' -ok rm {} ';'"],
  ["find . -type f -fprint list.txt", "Ran find . -type f -fprint list.txt"],
  ["fd -e tmp -x rm {}", "Ran fd -e tmp -x rm {}"],
  // A request that sends a body or a file is not a fetch.
  [
    "curl --upload-file artifact.tar https://example.com/upload",
    "Ran curl --upload-file artifact.tar https://example.com/upload",
  ],
  ["curl -T artifact.tar https://example.com/upload", "Ran curl -T artifact.tar https://example.com/upload"],
  ["curl -XPOST https://example.com/hook", "Ran curl -XPOST https://example.com/hook"],
  ["curl -X PUT https://example.com/items/1", "Ran curl -X PUT https://example.com/items/1"],
  ["curl -X DELETE https://example.com/items/1", "Ran curl -X DELETE https://example.com/items/1"],
  [`curl -d '{"a":1}' https://example.com/hook`, `Ran curl -d '{"a":1}' https://example.com/hook`],
  ["curl -sdname=x https://example.com/hook", "Ran curl -sdname=x https://example.com/hook"],
  ["curl --data-urlencode q=x https://example.com/hook", "Ran curl --data-urlencode q=x https://example.com/hook"],
  ["curl -F file=@a.png https://example.com/upload", "Ran curl -F file=@a.png https://example.com/upload"],
  ["curl --form file=@a.png https://example.com/upload", "Ran curl --form file=@a.png https://example.com/upload"],
  ["curl -fsSL https://example.com/notes.txt", "Fetched example.com/notes.txt"],
  // rg --files lists; patterns from a file, or several, are not one word on the line.
  ["rg --files webviews/src", "Listed webviews/src"],
  ["rg --files", "Listed files"],
  ["rg -f patterns.txt webviews/src", "Ran rg -f patterns.txt webviews/src"],
  ["rg --file patterns.txt webviews/src", "Ran rg --file patterns.txt webviews/src"],
  ["grep -rf patterns.txt src", "Ran grep -rf patterns.txt src"],
  ["rg -e foo -e bar src", "Ran rg -e foo -e bar src"],
  ["rg --regexp foo src", "Searched for “foo”"],
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

test("a running command reads as written until it finishes; cleaning is for finished labels only", () => {
  const item = shell(`agent-memory search "better tooltips" 2>/dev/null | head -10`, {
    status: "in_progress",
  });
  expect(label(item)).toBe(`Running agent-memory search "better tooltips" 2>/dev/null | head -10`);
});

test("the live line names the command as written, whitespace normalised", () => {
  // turns.ts runningLabel: no action, no cleaning (#36940).
  for (const status of ["in_progress", "completed"]) {
    const tool = shell("git status   2>/dev/null | head -5", { status }).tool!;
    expect(toolLabel(tool, "Bash", (command) => command, undefined, undefined, false)).toBe(
      "git status 2>/dev/null | head -5",
    );
  }
});

// A destructive command never reads as a benign one: it says what it does, or reads as its line.
const DESTRUCTIVE: [command: string, label: string][] = [
  ["git push origin :lane/old", "Deleted remote branch lane/old"],
  ["git push origin --delete lane/old", "Deleted remote branch lane/old"],
  ["git push -d origin lane/old", "Deleted remote branch lane/old"],
  ["git push origin +HEAD:lane/x", "Force-pushed lane/x"],
  ["git push --force-with-lease origin HEAD:lane/x", "Force-pushed lane/x"],
  ["git push -f", "Force-pushed commits"],
  ["git push origin a :b", "Ran git push origin a :b"],
  ["git push --mirror backup", "Ran git push --mirror backup"],
  ["git reset --hard origin/main", "Ran git reset --hard origin/main"],
  ["git clean -fdx", "Ran git clean -fdx"],
  ["git checkout -- .", "Ran git checkout -- ."],
  ["git checkout .", "Ran git checkout ."],
  ["git checkout -f main", "Ran git checkout -f main"],
  ["git switch --discard-changes main", "Ran git switch --discard-changes main"],
  ["git branch -D lane/old", "Ran git branch -D lane/old"],
  ["rm -rf build", "Removed build"],
  ["gh pr close 12", "Ran gh pr close 12"],
  ["gh pr merge 12 --squash --delete-branch", "Ran gh pr merge 12 --squash --delete-branch"],
  ["gh pr merge 12 --admin", "Ran gh pr merge 12 --admin"],
  ["gh run cancel 4061", "Ran gh run cancel 4061"],
  ["gh api -X DELETE repos/o/r/git/refs/heads/x", "Ran gh api -X DELETE repos/o/r/git/refs/heads/x"],
  ["gh api repos/o/r/issues/1/comments -f body=hi", "Ran gh api repos/o/r/issues/1/comments -f body=hi"],
  ["find . -name '*.orig' -delete", "Ran find . -name '*.orig' -delete"],
  ["find build -type f -exec rm {} +", "Ran find build -type f -exec rm {} +"],
  ["fd -e log -x rm", "Ran fd -e log -x rm"],
  ["cat a.txt > b.txt", "Ran cat a.txt > b.txt"],
  ["head -5 a.txt | tee b.txt", "Ran head -5 a.txt | tee b.txt"],
  ["cat $(rm -rf x)", "Ran cat $(rm -rf x)"],
  ["lane-gh push manaflow-ai/cmux lane/x --force", "Ran lane-gh push manaflow-ai/cmux lane/x --force"],
];

for (const [command, expected] of DESTRUCTIVE)
  test(`destructive: ${command} reads "${expected}"`, () => {
    expect(label(shell(command))).toBe(expected);
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

// A verb says what a command did, so a call that failed, was denied or a hook blocked never gets
// one: it reads as its line, and a group with one counts its commands.
const HOOK = "PreToolUse:Bash hook error: Blocked: the fixture guard needs a passing review first.";
test("a failed, denied or hook-blocked call reads as its line, never as done", () => {
  const merge = "gh pr merge 101 --squash --match-head-commit 0123456789abcdef";
  expect(label(shell(merge, { status: "failed", output: HOOK }))).toBe(`Ran ${merge}`);
  expect(label(shell("git push origin main", { status: "failed", output: "Exit code 1\n! [rejected] main" }))).toBe(
    "Ran git push origin main",
  );
  expect(label(shell("rm -rf build", { exitCode: 1 }))).toBe("Ran rm -rf build");
  expect(label(shell("git push origin main", { status: "completed", exitCode: 0 }))).toBe("Pushed main");
  // Its description is what the model meant to do, not a claim that it did.
  expect(label(shell(merge, { status: "failed", output: HOOK, description: "Merge the fixture PR" }))).toBe(
    "Merge the fixture PR",
  );
});

test("a group with a failed call says no verb for it", () => {
  const merges = commands("gh pr merge 101", "gh pr merge 101");
  expect(toolGroupLabel(t, "commands", merges)).toBe("Merged PR #101 twice");
  merges[1]!.tool!.status = "failed";
  expect(toolGroupLabel(t, "commands", merges)).toBe("Ran 2 commands");
  const pushes = commands("git push origin main", "git push origin main");
  pushes[0]!.tool!.exitCode = 1;
  expect(toolGroupLabel(t, "commands", pushes)).toBe("Ran 2 commands");
});

// A command word that names an Object.prototype member is not a rule: it falls back to the plain
// command line instead of throwing (which would trip the pane's error boundary on every reload).
for (const command of [
  "__proto__",
  "git __proto__",
  "gh pr __proto__",
  "gh __proto__ list",
  "constructor",
  "git toString",
]) {
  test(`${command} falls back without throwing`, () => {
    expect(() => commandAction(command)).not.toThrow();
    expect(commandAction(command)).toBeUndefined();
  });
}

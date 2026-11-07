// l10n-allow-file: test fixtures (real command lines and the English the rows draw).
// Real compound commands from agent transcripts (Claude's Bash calls and Codex's exec calls),
// home paths and session ids taken out. Leo, 2026-11-07, on a row that read "Ran 0*.mov) …":
// "It only showed the zero asterisk dot MOV, which is worse than, like, ran whatever. ... surely
// you can make it, like, stretch across the line a little bit more". A command splits on `;`,
// `&&`, `||`, pipes, `$( )`, backticks and subshells (quotes, heredocs and multi-line `-c "…"`
// strings respected); a step that only feeds another (`V=$(ls …)`, `echo`, `cd`) is plumbing; the
// table names the step that does the work, else the row shows its programs and the files they ran
// on. No label is a fragment of a word.
import { expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { toolLabel } from "../toolPaths";
import { shortCommand } from "./shortCommand";

const t = translatorFor("en");
let next = 0;

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const shell = (command: string, extra: Partial<Tool> = {}): Tool => ({
  id: `real-${next++}`,
  title: "Bash",
  kind: "execute",
  status: "completed",
  command,
  ...extra,
});

const label = (tool: Tool) => {
  const running = tool.status === "in_progress" || tool.status === "pending";
  return toolLabel(
    tool,
    "Bash",
    (command) => t(running ? "tools.runningCommand" : "tools.ranCommand", { command }),
    undefined,
    t(running ? "tools.runningUnnamed" : "tools.ranUnnamed"),
  );
};

/// Leo's command (2026-11-07 screenshot), its script shortened.
const LEO = [
  `V=$(ls "/Users/USER/Library/Application Support/cmux/Chat Uploads/sessions/SESSION/0/"*.mov); `,
  `ffmpeg -v error -i "$V" -vf "format=gray" -f rawvideo - 2>/dev/null | python3 -c "\n`,
  `import sys\ndata = sys.stdin.buffer.read()\nw, h = 64, 36\nprint(len(data) // (w * h))\n"`,
].join("");

const CASES: [command: string, label: string][] = [
  [LEO, "Ran ffmpeg → python3 on *.mov"],
  // An assignment that only feeds a later step, then the step that does the work.
  [
    "cd ~/Projects/checkouts/cmux/lane--x && H=$(git rev-parse HEAD); echo $H; timeout 200 gh pr merge 32695 --squash --match-head-commit $H 2>&1 | tail -5",
    "Merged PR #32695",
  ],
  [
    "base=$(git -C ~/mirrors/cmux.git merge-base feat-cmux-next 4db2c3f80ebc); git -C ~/mirrors/cmux.git show \"$base\":webviews/src/agent-session/acpmux/ComposerQueue.ts",
    "Read ComposerQueue.ts",
  ],
  // An assignment that runs real work names that work, never a fragment of the line.
  [
    `K=$(scripts/cmux-next/pin-cmux-tui.sh key 2>/dev/null | tail -1); echo "key=$K"; curl -fsS --max-time 15 https://files.example.com/cmux-tui/tree/$K/source.json; echo; ls scripts/cmux-next | grep -i tui`,
    "Ran pin-cmux-tui.sh key …",
  ],
  [
    `cd ~/ux-owner; R=$(timeout 100 ~/Projects/leo-workspace/tools/repo-tools resolve manaflow-ai/cmux pr/28179 2>/dev/null | tail -1); echo "28179 ref $R"`,
    "Ran repo-tools resolve manaflow-ai/cmux pr/28179 …",
  ],
  [
    `id=$(timeout 60 cmux-ci status --ref 2faef0a6ab5d 2>&1 | python3 -I -c "import sys,json\nprint(next(j['id'] for j in json.load(sys.stdin)))"); echo $id; timeout 6000 cmux-ci wait $id --timeout 5900 2>&1 | tail -2`,
    "Ran cmux-ci status → python3 …",
  ],
  // A pipeline into inline code: its programs, and the files they ran on when it names any.
  [
    `acpmux ls --json 2>/dev/null | python3 -c "\nimport json,sys\nd=json.load(sys.stdin)\nfor s in d:\n  print(s.get('name'))"`,
    "Ran acpmux ls → python3",
  ],
  [
    `export LANE_GH_LANE=cloud-client-rust; timeout 60 lane-gh call get manaflow-ai/cmux '{"path":"actions/workflows/risk-tier.yml/runs"}' 2>/dev/null | python3 -c "\nimport json,sys;d=json.load(sys.stdin)['data']\nfor r in d['workflow_runs']:\n  print(r['id'])"`,
    "Ran lane-gh call get → python3",
  ],
  [
    `cat .github/runners.json | python3 -c "import json,sys; print(list(json.load(sys.stdin)))"`,
    "Ran cat → python3 on runners.json",
  ],
  [
    `until s=$(cmux-ci status c95330e27065 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])'); [ "\${s%% *}" != "queued" ]; do sleep 60; done; echo "$s"`,
    "Ran cmux-ci status → python3 …",
  ],
  // Multi-line `-c` code on its own: its first line, never the whole script.
  [
    `python3 -c "\nimport json\nd=json.load(open('.github/runners.json'))\nprint([k for k in d])"`,
    `Ran python3 -c "import json …"`,
  ],
  // Heredoc bodies are never steps.
  [
    `F=webviews/src/agent-session/acpmux/Localizable.xcstrings; python3 - "$F" <<'EOF'\nimport sys,re\np=sys.argv[1]; s=open(p).read()\nprint(len(s))\nEOF`,
    `Ran python3 - "$F" <<'EOF'`,
  ],
  [
    `PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'\nfrom pathlib import Path\nprint(Path('.').resolve())\nPY\nrg -n 'ThreadPoolExecutor' tools/test_pr_overlap.py`,
    "Ran python3 - <<'PY' …",
  ],
  [
    `cd webviews && grep -rn "text-control--line-height:" src/pages/shared/desktop.css | head -2; python3 - <<'EOF'\np='src/ui/popupSurface.css'\ns=open(p).read()\nEOF`,
    "Searched for “text-control--line-height:” …",
  ],
  // Subshells and loops split into their steps.
  ["(cd cmux-tui && cargo test -p acpmux --lib 2>&1 | tail -60)", "Ran tests with cargo"],
  [
    `for f in /tmp/sidebar-first.log /tmp/sidebar-core.log; do echo "--- $f"; wc -c "$f"; tail -100 "$f"; done`,
    `Ran wc -c "$f" …`,
  ],
  // `cd X && …`, env prefixes and plumbing steps around the work.
  ["cd ~/Projects/checkouts/cmux/x && git status | head -5; git log --oneline -1; ls", "Checked git status …"],
  ["CMUX_BROWSER_TESTS=1 bun test test/live-line-lead-tone-browser.test.ts 2>&1 | tail -20", "Ran tests in live-line-lead-tone-browser.test.ts"],
  ["M=~/mirrors/cmux.git; git -C $M log --format='%h %cr %s' -2 origin/main 2>/dev/null", "Read git history"],
  [`echo "head: $(git rev-parse HEAD)"; git log --oneline -3`, "Read git history"],
  ["pwd && git status --short", "Checked git status"],
  ["git diff --check && git diff --stat && git commit --amend --no-edit && git rev-parse HEAD", "Viewed the diff …"],
  ["git status --short --branch && git fetch origin feat-cmux-next && git rev-parse origin/feat-cmux-next", "Checked git status …"],
  // Codex's readers.
  ["nl -ba Tests/CmuxNextDesignTests/CmuxToastSurfaceTests.swift | sed -n '1,360p'", "Read CmuxToastSurfaceTests.swift"],
  ["rg -n 'SidebarInsertMotion' Packages/macOS/CmuxNext/Sources | head -100", "Searched for “SidebarInsertMotion”"],
  ["git -C ~/.scratch/card/cmux.git show --no-patch --pretty=raw fa96f61e80f6 | head -35", "Viewed fa96f61e80f6"],
  // Code inside a word: the table names nothing, the line reads as written.
  [
    `lane-gh call issue_create manaflow-ai/cmux "$(cat /tmp/briefs/followup-1.json)"`,
    `Ran lane-gh call issue_create manaflow-ai/cmux "$(cat /tmp/briefs/followup-1.json)"`,
  ],
  ["ls -l $(which pr-owner 2>/dev/null) 2>/dev/null", "Ran ls -l $(which pr-owner 2>/dev/null)"],
  ["ps -eo pid,ppid,args | rg 'git (fetch|gc)'", "Ran ps -eo pid,ppid,args | rg 'git (fetch|gc)'"],
  [`which convert magick ffmpeg; python3 -c "import numpy" 2>&1`, "Ran which convert magick ffmpeg …"],
  // An assignment that runs something destructive is the step it names.
  ["X=$(rm -rf build); ls", "Removed build …"],
];

for (const [command, expected] of CASES)
  test(`${command.replace(/\n/g, "⏎").slice(0, 120)} reads "${expected}"`, () => {
    expect(label(shell(command))).toBe(expected);
  });

test("no label is a fragment of a word: every word it shows is whole in the command", () => {
  for (const [command] of CASES) {
    for (const status of ["completed", "in_progress"] as const) {
      const text = label(shell(command, { status }));
      expect(text).not.toContain("0*.mov)");
      expect(text).not.toMatch(/^(?:Ran|Running) [^\s]*\)/);
    }
  }
});

test("the live line and a running row name the working step as written, not its plumbing", () => {
  const live = toolLabel(shell(LEO, { status: "in_progress" }), "Bash", (command) => command, undefined, undefined, false);
  expect(live.startsWith(`ffmpeg -v error -i "$V" -vf "format=gray" -f rawvideo - 2>/dev/null | python3 -c "`)).toBe(true);
  expect(shortCommand(LEO).startsWith("ffmpeg -v error")).toBe(true);
  expect(label(shell(LEO, { status: "in_progress" })).startsWith("Running ffmpeg -v error")).toBe(true);
  // The setup's assignment stays whole: `K=$(… key | tail -1)` never reads "key …".
  expect(shortCommand(`K=$(scripts/pin.sh key 2>/dev/null | tail -1); echo "$K"`, Number.POSITIVE_INFINITY)).toBe(
    `K=$(scripts/pin.sh key 2>/dev/null | tail -1) …`,
  );
});

test("a description still names a command the table does not know", () => {
  expect(label(shell(LEO, { description: "Measure the video's frames" }))).toBe("Measure the video's frames");
});

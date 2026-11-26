// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A finished turn's closed "Worked for" says what it hides once Settings > Advanced > Experiments >
// Fold Summary Counts is on (think-tank finding 2026-11-22, transcript sweep 1: "Fold summary:
// duration only / with counts" for Leo's pick, default stays today's until chosen): "Worked for 36s
// · ran 4 commands, edited 2 files" in the line's quiet tone, the runs' "(1 failed)" in the failure
// tone, one line cut from the right, the chevron and the click target as they were.
// Test: foldSummaryCounts.test.tsx.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { FOLD_COUNTS_SWITCH } from "./turns";

const run = (description: string, command: string, failed = false): AcpmuxActivity =>
  tool(command, "execute", failed ? "failed" : "completed", {
    description,
    command,
    output: failed ? "error: 1 test failed\n" : "ok\n",
    exitCode: failed ? 1 : 0,
  });
const edit = (path: string): AcpmuxActivity => tool(`Edit ${path}`, "edit", "completed", { locations: [{ path }] });
const read = (path: string): AcpmuxActivity => tool(`Read ${path}`, "read", "completed", { locations: [{ path }] });
const search = (pattern: string): AcpmuxActivity => tool(`Search ${pattern}`, "search", "completed");
const fetch = (url: string): AcpmuxActivity => tool(`Fetch ${url}`, "fetch", "completed");

/// Four commands and two edits, then the reply: "Worked for 36s · ran 4 commands, edited 2 files".
function commandsAndEdits(failed = false): AcpmuxRow[] {
  return [
    user("Make uploads retry server errors", 10),
    activity(
      [
        run("Found the upload client", "rg -n 'uploadChunk' src"),
        run("Ran the upload tests", "bun test upload", failed),
        edit("src/upload/client.ts"),
        edit("src/upload/retry.ts"),
        run("Ran the upload tests again", "bun test upload"),
        run("Checked the branch", "git status --short"),
      ],
      9.8,
    ),
    assistant("Uploads now retry server errors with backoff, up to three times.", 9.3),
    summary(9.2, { status: "completed", durationMs: 36_000, toolCount: 6 }),
  ];
}

/// A long turn of every kind of work: the line runs past a narrow pane and is cut from the right.
function longTurn(): AcpmuxRow[] {
  return [
    user("Find why the nightly is slow and fix what you can", 30),
    activity(
      [
        read("scripts/nightly.sh"),
        read("scripts/build.sh"),
        read(".github/workflows/nightly.yml"),
        search("cache-key"),
        search("swift build"),
        fetch("https://github.com/manaflow-ai/cmux/actions"),
        run("Timed the build", "time scripts/build.sh"),
        run("Listed the slow steps", "gh run view 42 --log | rg 'took'", true),
        run("Timed the build again", "time scripts/build.sh"),
        edit("scripts/build.sh"),
        edit(".github/workflows/nightly.yml"),
        edit("scripts/cache.sh"),
      ],
      29,
    ),
    assistant(
      "The cache key changed on every run; it now hashes only the lockfiles, and the build takes 4m instead of 11m.",
      22,
    ),
    summary(21.9, { status: "completed", durationMs: 8 * 60_000 + 14_000, toolCount: 12 }),
  ];
}

const snapshot = (rows: AcpmuxRow[], family: string) => {
  const base = chat(rows, { title: "Fold summary counts", harness: family });
  return { ...base, summary: { ...base.summary!, family } };
};

const on = { [FOLD_COUNTS_SWITCH]: true };
const variant = (rows: AcpmuxRow[], note: string, counts: boolean, family = "claude"): AgentPaneVariant => ({
  note,
  snapshot: snapshot(rows, family),
  // The worked-line experiment's default arm is `time`; its `outcome` arm names the work. Every
  // variant pins the time arm, so this switch is what it compares.
  experiments: { "worked-line": "time" },
  ...(counts && { experimentSwitches: on }),
});

export default agentPaneEntry({
  id: "agent-pane.fold-summary-counts",
  title: "Fold summary counts",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 360, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor"],
  variants: {
    "duration-only": variant(
      commandsAndEdits(),
      "Default (the switch off): today's line, Worked for 36s and the chevron, nothing else.",
      false,
    ),
    counts: variant(
      commandsAndEdits(),
      "Switch on: Worked for 36s · ran 4 commands, edited 2 files, the counts in the line's quiet tone.",
      true,
    ),
    "counts-failed": variant(
      commandsAndEdits(true),
      "Switch on, a command failed: the runs' (1 failed) after the counts, in the failure tone.",
      true,
    ),
    "counts-codex": variant(commandsAndEdits(), "Switch on, the same turn in a Codex chat.", true, "codex"),
    "counts-long": variant(
      longTurn(),
      "Switch on, every kind of work: one line, cut from the right on a narrow pane; the time stays whole.",
      true,
    ),
  },
});

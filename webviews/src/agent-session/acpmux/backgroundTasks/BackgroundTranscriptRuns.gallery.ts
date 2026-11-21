// l10n-allow-file: gallery fixtures (prompts, subagent names, tool calls), not shipped UI.
// A helper's transcript opened from the Background tasks panel (SubagentTranscript.tsx), the work between
// its replies folded as Claude Code's drill-in folds it (Leo, 2026-11-09: "this claude background tasks
// thing and being able to click into subagents'/helpers' stuff is really good"): the helper's prose, and
// between two replies one quiet line per stretch of work, "Ran 4 commands, read a file and edited a file",
// that opens to each step; a lone call keeps its own line. Compare arms
// (transcriptRuns.experiment.ts): `runs` (shipped), `live` (the running stretch open), `every` (a lone
// call folds too), `lines` (before: every call and thought on its own line). Test:
// test/background-transcript-runs.test.ts.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";
import { transcriptRunsLook } from "./transcriptRuns.experiment";

const HELPER: Subagent = {
  id: "agent-udp",
  parent: null,
  name: "Cloud UDP media path",
  task: "Cloud UDP media path",
  kind: "general-purpose",
  state: "running",
  startedAt: minutesAgo(42),
  background: true,
};
const DOCS: Subagent = {
  id: "agent-docs",
  parent: null,
  name: "Check the transport docs",
  task: "Check the transport docs",
  kind: "Explore",
  state: "completed",
  startedAt: minutesAgo(30),
  endedAt: minutesAgo(26),
  background: true,
};

/// A shell call that started `minutes` ago and ran `seconds`.
const ran = (title: string, command: string, minutes: number, seconds: number, status = "completed") =>
  tool(title, "execute", status, {
    description: title,
    command,
    startedAt: minutesAgo(minutes),
    endedAt: minutesAgo(minutes) + seconds * 1000,
    output: status === "failed" ? "error: clippy found 1 warning in test code" : "ok",
    ...(status === "failed" ? { exitCode: 1 } : {}),
  });
const read = (path: string, minutes: number) =>
  tool(`Read ${path}`, "read", "completed", { locations: [{ path }], startedAt: minutesAgo(minutes) });
const edit = (path: string, minutes: number) =>
  tool(`Edit ${path}`, "edit", "completed", { locations: [{ path }], startedAt: minutesAgo(minutes) });

/// The helper's own transcript: prose between stretches of work, one failed call, one live stretch.
const helperView = (): AcpmuxRow[] => [
  user("Give NEXT Cloud a UDP media path with a fallback to TCP", 42, { id: "udp-ask" }),
  activity([thought("Reading how the transport picks its path first.")], 41.5, { id: "udp-think" }),
  activity([read("crates/transport/src/path.rs", 41.2)], 41.2, { id: "udp-read-1" }),
  activity([read("crates/transport/src/udp.rs", 41)], 41, { id: "udp-read-2" }),
  activity([ran("Find the path picker's callers", "rg -n pick_path crates", 40.8, 1)], 40.8, { id: "udp-grep" }),
  assistant("The picker already ranks paths; the Cloud relay just never offers UDP. Adding it there.", 40, {
    id: "udp-note-1",
  }),
  activity([edit("crates/relay/src/offer.rs", 38)], 38, { id: "udp-edit" }),
  activity([thought("Now the tests for the new offer.")], 37.5, { id: "udp-think-2" }),
  activity([ran("Run the relay tests on the fleet", "cmux-ci test -- cargo test -p relay", 37, 92)], 37, {
    id: "udp-test",
  }),
  activity([ran("Lint the relay crate", "cmux-ci test -- cargo clippy -p relay", 34, 61, "failed")], 34, {
    id: "udp-lint",
  }),
  activity([read("crates/relay/tests/offer.rs", 33)], 33, { id: "udp-read-3" }),
  activity([ran("Fix the lint and lint again", "cmux-ci test -- cargo clippy -p relay", 32, 58)], 32, {
    id: "udp-lint-2",
  }),
  assistant("Lint is green. Pushing, then waiting on the PR's checks and review.", 30, { id: "udp-note-2" }),
  activity([ran("Push the branch", "git push -u origin cloud-udp", 29.5, 3)], 29.5, { id: "udp-push" }),
  assistant("Pushed. Opening the PR with the test counts in its body.", 29, { id: "udp-note-3" }),
  activity(
    [
      ran("Open the PR", "gh pr create --fill", 28, 4),
      ran("Read the review receipt", "gh pr view 39121 --json reviews", 12, 2),
      tool("Wait for PR checks and review", "execute", "in_progress", {
        description: "Wait for PR checks and review",
        command: "gh pr checks 39121 --watch",
        startedAt: minutesAgo(2.4),
      }),
    ],
    28,
    { id: "udp-live" },
  ),
];

/// A helper that worked a long while without a word: 240 calls, more than the transcript mounts at
/// once (subagentTranscriptModel.ts `MOUNTED`), all one run.
const longView = (): AcpmuxRow[] => [
  user("Sweep every crate for the old path picker", 42, { id: "long-ask" }),
  ...Array.from({ length: 240 }, (_, index) =>
    activity(
      [ran(`Check crate ${index + 1}`, `rg -n pick_path crates/c${index + 1}`, 41 - index * 0.1, 1)],
      41 - index * 0.1,
      {
        id: `long-step-${index}`,
      },
    ),
  ),
];

const snapshotWith = (view: AcpmuxRow[]) =>
  chat(
    [
      user("Get the Cloud media path onto UDP and check the transport docs", 43),
      row(SUBAGENTS, 42, { id: "runs-group", subagents: [HELPER, DOCS] }),
      assistant("Two helpers are on it; I'll report when each is back.", 41.8),
      summary(41.8, { status: "completed", durationMs: 12_000 }),
    ],
    {
      title: "Cross-account chat visibility",
      subagentViews: {
        [HELPER.id]: view,
        [DOCS.id]: [
          user("Check the transport docs", 30, { id: "docs-ask" }),
          assistant("The docs already describe the path picker; nothing to change.", 26, { id: "docs-done" }),
        ],
      },
    },
  );
const snapshot = snapshotWith(helperView());

const drill = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: "Chat actions" });
  await ctx.click({ role: "menuitem", name: "Background tasks" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-bg"));
  await ctx.click({ selector: `.acpmux-bg__group[data-group="agent:${HELPER.id}"] .acpmux-bg__name` });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-bg__transcript [data-row-id]"));
};

export default agentPaneEntry({
  id: "agent-pane.background-tasks-runs",
  title: "Background tasks: a helper's work between replies",
  area: "Agent pane",
  height: 760,
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/backgroundTasks/SubagentTranscript.tsx",
    "agent-session/acpmux/backgroundTasks/subagentTranscriptModel.ts",
  ],
  experiment: {
    definition: transcriptRunsLook,
    script: [{ name: "open the helper's transcript", run: drill }],
  },
  variants: {
    drill: {
      note: "A helper opened from the panel: its prose, and between two replies one line per stretch of work; a lone call keeps its own line; the last stretch still runs, with the spinner under it.",
      snapshot,
      play: drill,
    },
    "long-run": {
      note: 'A helper\'s 240 calls with no reply between, more than the transcript mounts at once: one line, "Ran 240 commands", and the transcript holds still (it pages by what it draws, not by rows).',
      snapshot: snapshotWith(longView()),
      play: drill,
    },
    "run-open": {
      note: 'The stretch with the failed lint opened in place: "Edited a file, ran 3 commands, and performed 1 other action, 1 failed", then its steps, each call opening to what it ran and said.',
      snapshot,
      play: async (ctx) => {
        await drill(ctx);
        await ctx.click({ selector: '.acpmux-bg__run[data-run-id="udp-edit"] .acpmux-bg__line--fold' });
        await ctx.waitFor(() =>
          ctx.document.querySelector('.acpmux-bg__run[data-run-id="udp-edit"] .acpmux-bg__run-steps'),
        );
      },
    },
  },
});

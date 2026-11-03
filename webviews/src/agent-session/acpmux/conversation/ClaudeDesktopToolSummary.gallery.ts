// l10n-allow-file: gallery fixtures (sample prompts, commands and outputs), not shipped UI.
// A run of shell calls summarized as Claude Code desktop summarizes one (Leo, 2026-11-03: "hmm claude
// code desktop's summarization of tool calls/parsing of them seem kinda good?"): a header that counts
// what happened, "Finished 2 background tasks, ran 5 commands (2 failed)", with its chevron; one row
// per call titled by its description, a failed one tagged "Failed" in red before its chevron; opened,
// the command in its code colours, "Exit code N" in red, then the output in mono; a background
// command's end noted as "Background command completed <command>". Our colours, glass, fonts and row
// grid stay. Reference: cmux-design-references claude/live/transcript-tool-call-group-summary.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { AcpmuxActivity } from "../model";
import type { PlayContext } from "../../../gallery/play";

const times = (at: number, ran = 0.05) => ({ startedAt: minutesAgo(at), endedAt: minutesAgo(at - ran) });

const shell = (
  command: string,
  description: string | undefined,
  status: "completed" | "failed" | "in_progress",
  at: number,
  extra: Partial<NonNullable<AcpmuxActivity["tool"]>> = {},
) =>
  tool(command, "execute", status, {
    command,
    ...(description ? { description } : {}),
    ...(status === "in_progress" ? { startedAt: minutesAgo(at) } : times(at)),
    ...extra,
  });

/// Two background commands that ended, two calls that failed (one of them in the background), and
/// two that went through, described as the agent described them.
const mixed = (described = true) => {
  const d = (words: string) => (described ? words : undefined);
  return [
    shell("rg -n 'retryDelay' src/net", d("Find retryDelay references in the network layer"), "completed", 6, {
      background: { state: "completed", endedAt: minutesAgo(5.2) },
      output: "src/net/retry.ts:14:export const retryDelay = (n: number) => 250 * 2 ** n;\n",
    }),
    shell(
      "f=fixtures/retry-cases.json; ls $f 2>&1; [ -f $f ] && jq '.cases | length' $f",
      d("Count the retry fixture cases"),
      "failed",
      5.8,
      { output: "Exit code 1\nls: fixtures/retry-cases.json: No such file or directory" },
    ),
    shell("bun test src/net/retry.test.ts", d("Run the retry tests"), "completed", 5.6, {
      output: "12 pass\n0 fail\n",
    }),
    // A background shell that failed there: its launch completed, its background state failed.
    shell("curl -sf http://localhost:4000/health", d("Check the local API is up"), "completed", 5.4, {
      background: { state: "failed", endedAt: minutesAgo(4.9) },
      output: "Exit code 7\ncurl: (7) Failed to connect to localhost port 4000",
    }),
    shell("git log --oneline -5 -- src/net", d("List recent network-layer commits"), "completed", 5.2, {
      output: "a1b2c3d net: retry on 503\n9f8e7d6 net: typed errors\n",
    }),
  ];
};

const finished = (items: AcpmuxActivity[]) =>
  chat([
    user("Why does the fetch helper give up after one retry?", 7),
    activity(items, 6),
    assistant(
      "`retryDelay` is fine; the fixture list the tests read is missing, so the retry cases never run. The local API was down, so the health check failed too.",
      4.5,
    ),
  ]);

/// Two background commands still running, one that finished, as the turn goes on.
const running = chat(
  [
    user("Start the API and the worker, then watch the logs", 3),
    activity(
      [
        shell("bun run dev:api", "Start the API server", "completed", 2.8, {
          background: { state: "running" },
        }),
        shell("bun run dev:worker", "Start the queue worker", "completed", 2.6, {
          background: { state: "running" },
        }),
        shell("bun run migrate", "Apply pending migrations", "completed", 2.4, {
          background: { state: "completed", endedAt: minutesAgo(2) },
        }),
      ],
      2.8,
    ),
  ],
  { isWorking: true },
);

/// A background command whose call is on a page not loaded: only its end is noted.
const notes = chat([
  user("Did the nightly import finish?", 4),
  row("backgroundTask", 3.5, {
    backgroundTask: { toolCallId: "gallery-bg-1", command: "python3 scripts/import_nightly.py", state: "completed" },
  }),
  row("backgroundTask", 3.4, {
    backgroundTask: { toolCallId: "gallery-bg-2", command: "python3 scripts/reindex.py", state: "failed" },
  }),
  assistant("The import finished; the reindex failed and needs a rerun.", 3.3),
]);

/// Opens the run, then its failed call, to show the command, its exit code and its output.
const openFailed = async (ctx: PlayContext) => {
  await openRun(ctx);
  // The first failed step is "Count the retry fixture cases", the run's second call. Trusted input
  // lands at its on-screen point, so wait for the opening run to stop moving before clicking it.
  const failed = { selector: ".cv-step > .cv-command:has(> .cv-command__failed)" };
  let last = Number.NaN;
  await ctx.waitFor(() => {
    const row = ctx.find(failed);
    row.scrollIntoView({ block: "nearest" });
    const { top, left, width, height } = row.getBoundingClientRect();
    const still = top === last;
    last = top;
    const hit = ctx.document.elementFromPoint(left + width / 2, top + height / 2);
    return still && Boolean(hit && row.contains(hit));
  });
  await ctx.click(failed);
  await ctx.waitFor(() => ctx.find(failed).getAttribute("aria-expanded") === "true");
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-shell__exit")));
};

/// Opens the run's group, unless it already shows open (a run with a failed call may open on its own).
const openRun = async (ctx: PlayContext) => {
  const header = { role: "button", name: /Finished 2 background tasks/ } as const;
  if (ctx.find(header).getAttribute("aria-expanded") !== "true") await ctx.click(header);
  await ctx.waitFor(() => ctx.find(header).getAttribute("aria-expanded") === "true");
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-step > .cv-command").length === 5);
};

export default agentPaneEntry({
  id: "agent-pane.claude-desktop-tool-summary",
  title: "Tool call summary, as Claude Code desktop draws it",
  area: "Agent pane",
  height: 620,
  covers: [
    "agent-session/acpmux/conversation/FailedCount.tsx",
    "agent-session/acpmux/conversation/CommandRow.tsx",
    "agent-session/acpmux/conversation/ShellBlock.tsx",
    "agent-session/acpmux/conversation/BackgroundTaskNote.tsx",
    "agent-session/acpmux/conversation/toolRunSummary.ts",
  ],
  keywords: ["claude", "tool", "summary", "background", "failed", "exit code", "commands"],
  variants: {
    collapsed: {
      note: "Chosen. Mixed background and failed calls as the turn first draws them, under Finished 2 background tasks, ran 5 commands (2 failed).",
      snapshot: finished(mixed()),
    },
    opened: {
      note: "The run opened (opened here if it is not already): one row per call by its description, the failed ones tagged Failed.",
      snapshot: finished(mixed()),
      play: openRun,
    },
    "failed-open": {
      note: "The failed call opened: $ command, Exit code 1 in red, then its output in mono.",
      snapshot: finished(mixed()),
      play: openFailed,
    },
    running: {
      note: "Two background commands still running, one finished: running titles shimmer, the header counts the finished one.",
      snapshot: running,
    },
    "no-description": {
      note: "Calls with no description fall back to Ran <command>.",
      snapshot: finished(mixed(false)),
      play: openRun,
    },
    "background-notes": {
      note: "A background command's end without its call: Background command completed (muted), then the command.",
      snapshot: notes,
    },
  },
});

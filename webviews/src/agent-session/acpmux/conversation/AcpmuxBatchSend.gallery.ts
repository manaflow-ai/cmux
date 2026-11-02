// l10n-allow-file: gallery fixtures (sample commands, session names and messages), not shipped UI.
// Several messages from one call, each its own sent-message row (acpmuxSends.ts `acpmuxSendBatch`,
// acpmuxMcpSends.ts, SentMessageLine.tsx), never summed up under one line (Leo 2026-10-31: "this
// +11 is really bad you guys should just render them all separately"). Leo 2026-10-30: "these
// should be properly rendered too/acpmux batch send tools given to you rendered consistently with
// other stuff". The shapes: a coordinator's shell
// function batch (`s(){ acpmux send … "$1" "$(cat "$2")"; }; s a a.md; s b b.md`), a `for` loop, a
// `&&` chain, and the acpmux MCP send's `messages` (#28671). Names and messages are made up.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const bash = (command: string, description: string, status: string, output?: string) =>
  tool(command.slice(0, 120), "execute", status, { command, description, ...(output !== undefined && { output }) });

const FUNCTION_BATCH = bash(
  'cd /tmp/coord; s(){ acpmux send --no-wait --from coord "$1" "$(cat "$2")" 2>&1 | tail -1; }; s build-box/nightly escalate-nightly.md; s gcp-lane/acpmux-owner relay-owner.md; s review-astra rereview-4182.md',
  "Escalate legacy nightly, relay to owners",
  "completed",
  'queued\nsteered\nacpmux: no_session: no session matches "review-astra"',
);
const LOOP_BATCH = bash(
  'for lane in tests docs perf; do acpmux send --no-wait "$lane" "$(cat "/tmp/briefs/$lane.md")"; done',
  "Brief the three lanes",
  "completed",
  "queued\nqueued\nqueued",
);
const CHAIN = bash(
  "acpmux send --no-wait tests 'Rebase on #4182 before you touch the dock.' && acpmux send --no-wait docs 'The retry banner copy is final.'",
  "Tell tests and docs",
  "completed",
  "queued\nqueued",
);
const MCP_BATCH = tool("mcp__cmux__acpmux_send", "other", "completed", {
  inputSummary: JSON.stringify({
    steer: true,
    messages: [
      { to: "tests", text: "Also cover the retry backoff.\nReport the failing cases first." },
      { tag: "area=docs", file: "/tmp/briefs/docs.md" },
    ],
  }),
  output: JSON.stringify({
    results: [
      { index: 0, to: "tests", target: "01a1aaaa", ok: true, status: "delivered", delivery: "next_step" },
      {
        index: 1,
        tag: "area=docs",
        to: "docs-a",
        target: "peer/01a1bbbb",
        ok: true,
        status: "delivered",
        delivery: "queued",
      },
      {
        index: 1,
        tag: "area=docs",
        to: "docs-b",
        target: "peer/01a1cccc",
        ok: true,
        status: "delivered",
        delivery: "queued",
      },
    ],
    sent: 3,
    failed: 0,
  }),
});
const RUNNING = bash(
  'for lane in tests docs; do acpmux send "$lane" "$(cat "/tmp/briefs/$lane.md")"; done',
  "Brief tests and docs and wait for replies",
  "in_progress",
);

const turn = (calls: ReturnType<typeof tool>[], working = false) =>
  chat(
    [
      user("Escalate the nightly, brief the lanes, and tell tests and docs.", 4),
      activity(calls, 3.8),
      ...(working
        ? []
        : [
            assistant("Sent. review-astra is not running; starting it next.", 3.5),
            summary(3.5, { status: "completed" }),
          ]),
    ],
    { title: "coord", ...(working && { isWorking: true }) },
  );

/// Opens the finished turn, so each message's own row shows.
const openTurn: Play = async (ctx) => {
  if (ctx.document.querySelector(".cv-worked.is-toggle")) {
    await ctx.click({ selector: ".cv-worked.is-toggle" });
    await ctx.waitFor(() => ctx.document.querySelector(".cv-sent"));
  }
};

/// Opens the turn, then the first message's Raw: the whole shell function stays one click away.
const openRaw: Play = async (ctx) => {
  await openTurn(ctx);
  await ctx.click({ selector: ".cv-sent" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subsession__under .cv-subsession__toggle"));
  await ctx.click({ selector: ".cv-subsession__under .cv-subsession__toggle" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subsession__under .cv-shell"));
};

const ALL = [FUNCTION_BATCH, LOOP_BATCH, CHAIN, MCP_BATCH];

export default agentPaneEntry({
  id: "agent-pane.acpmux-batch-send",
  title: "Batched acpmux sends",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/conversation/acpmuxSends.ts", "agent-session/acpmux/conversation/acpmuxMcpSends.ts"],
  variants: {
    batches: {
      note: 'Default: a shell function batch, a for loop, a && chain and an MCP messages batch, one sent-message row per recipient, each on its own; a file-sourced message names its file; one message acpmux refused reads "Couldn\'t send".',
      snapshot: turn(ALL),
      play: openTurn,
    },
    "batch-raw": {
      note: "The function batch's first message opened: Raw keeps the whole shell command, the function and both calls.",
      snapshot: turn([FUNCTION_BATCH]),
      play: openRaw,
    },
    "batch-sending": {
      note: "A loop batch in flight: each message is its own row and reads Sending to, with no spinner on the row.",
      theme: { codexToolRuns: false },
      snapshot: turn([RUNNING], true),
    },
  },
});

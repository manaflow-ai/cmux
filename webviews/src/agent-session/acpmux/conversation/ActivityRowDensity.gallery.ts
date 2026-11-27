// l10n-allow-file: gallery fixtures (sample lanes, messages, commands and hosts), not shipped UI.
// The activity rows of Leo's 2026-11-17 capture of a coordinator chat, "Worked for" opened and then
// folded (Leo: "expanded, then / folded worked // these are too big"): another machine's message
// with where it was sent from, "Ran cmux script (1 call)", two lanes' received lines, "Background
// task finished", a thinking line, "Sent to", the next "Worked for", "Received 3 messages" and its
// thinking line. Every one of them is one line of the shared row metric (rowMetric.ts: its height,
// text size, chip and glyph), so they read as a dense list. The density variants lay the three
// candidate metrics over the same rows; test/transcript-activity-row-density.test.ts measures them.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import {
  activity,
  assistant,
  chat,
  row,
  session,
  summary,
  thought,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "../model";
import { ROW_METRIC_VARIANTS, type RowMetric } from "../rowMetric";
import { incomingPrompt } from "./incomingMessage";

const exec = (script: string): AcpmuxActivity =>
  tool("mcp__cmux__cmux_exec", "other", "completed", {
    inputSummary: JSON.stringify({ script }),
    output: JSON.stringify({
      content: [{ type: "text", text: '{"calls":1}' }],
      structuredContent: { calls: 1, call_log: [{ name: "acpmux_bg_start", ok: true }], result: "bg-1eeb7aaf04a5" },
      isError: false,
    }),
  });
const send = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", {
    inputSummary: JSON.stringify({ to, message }),
    output: `delivered to ${to}\n`,
  });

/// Another agent's message that came in while the turn ran.
const received = (
  id: string,
  name: string,
  sessionId: string,
  text: string,
  minutes: number,
  fields: Partial<AcpmuxRow> = {},
) =>
  row("user", minutes, {
    id,
    text,
    continues: true,
    untyped: true,
    incoming: { kind: "message", message: { name, sessionId, harness: "codex", text, raw: text } },
    ...fields,
  } as Partial<AcpmuxRow>);

/// acpmux's inbox notice for three messages: the turn's prompt, "Received 3 messages".
function notice(minutes: number): AcpmuxRow {
  const threads = [
    { from: "protocol-tidy", text: "Stop met: merged." },
    { from: "ws-check-throughput", text: "PR #11968 body updated." },
    { from: "nightly-watch", text: "The nightly is green." },
  ].map(({ from, text }, index) => ({
    threadId: `from:${from}`,
    label: "",
    new: 1,
    from: [from],
    promptIds: [`density-wake-${index}`],
    preview: text,
    messages: [{ from, promptId: `density-wake-${index}`, text }],
  }));
  const text = [
    "[inbox] New messages from other agents in 3 threads.",
    ...threads.map((thread) => `- 1 new from ${thread.from[0]}: ${thread.preview} (thread ${thread.threadId})`),
  ].join("\n");
  return row("user", minutes, {
    id: "density-notice",
    text,
    untyped: true,
    incoming: incomingPrompt(text, {
      client: "acpmux",
      _meta: { provenance: { kind: "inbox_notice", noticeId: "density-wake", threads } },
    }) as AcpmuxRow["incoming"],
  } as Partial<AcpmuxRow>);
}

/// Leo's rows, in his capture's order.
export const DENSITY_ROWS = {
  remote: "density-remote",
  script: "density-script",
  protocol: "density-protocol",
  throughput: "density-throughput",
  task: "density-task",
  thinking: "density-thinking",
  sent: "density-sent",
  notice: "density-notice",
  thinkingNext: "density-thinking-next",
} as const;

function leosRows(): AcpmuxRow[] {
  const remoteText = "land-leo-typing-repair: #44387 head 5171b1e5. The review BLOCKs on the hold check.";
  return [
    user("Keep the lanes moving and land what is ready.", 40, { id: "density-first" }),
    assistant("On it.", 39.9, { id: "density-first-reply" }),
    summary(39.8, { id: "density-first-footer", status: "completed", durationMs: 2_000, toolCount: 0 }),
    received(DENSITY_ROWS.remote, "a session on another machine", "", remoteText, 20, {
      continues: undefined,
      sentFrom: {
        promptId: DENSITY_ROWS.remote,
        harness: "claude-code",
        label: "Claude Agent SDK",
        confirmed: false,
      },
    } as Partial<AcpmuxRow>),
    activity([exec('await cmux.call("acpmux_bg_start", {});')], 19.9, { id: DENSITY_ROWS.script }),
    received(
      DENSITY_ROWS.protocol,
      "protocol-tidy",
      "s-protocol",
      "stop met (merged, or open with an owner and a named blocker). Nothing left on the list.",
      19.8,
    ),
    received(
      DENSITY_ROWS.throughput,
      "ws-check-throughput",
      "s-throughput",
      "PR #11968 now has body updated successfully. Live head 14e93eded6f5395 and its checks run.",
      19.7,
    ),
    row("backgroundTask", 19.6, {
      id: DENSITY_ROWS.task,
      backgroundTask: { toolCallId: "bg-1eeb7aaf04a5", command: "bg-1eeb7aaf04a5", state: "completed" },
    }),
    activity(
      [
        thought(
          "The reviewer flagged this as not a strict fix, since processes over 500 now get capped at 500, which users would notice.",
        ),
      ],
      19.5,
      { id: DENSITY_ROWS.thinking },
    ),
    activity(
      [send("ask-21d2ea1b90", "#44893: re-review says 'Chat-hold not confirmed: chats with more than one hold'.")],
      19.4,
      {
        id: DENSITY_ROWS.sent,
      },
    ),
    assistant("Sent the re-review back to its lane.", 19.3, { id: "density-reply" }),
    summary(19.2, { id: "density-footer", status: "completed", durationMs: 13_000, toolCount: 3 }),
    notice(12),
    activity(
      [
        thought(
          "Most of the backlog needs nothing from me. The lane cap is over by one on two hosts, but that's warn-only, so I'll skip it.",
        ),
      ],
      11.9,
      { id: DENSITY_ROWS.thinkingNext },
    ),
    assistant("Nothing needs you; the backlog is moving.", 11.8, { id: "density-next-reply" }),
    summary(11.7, { id: "density-next-footer", status: "completed", durationMs: 7_000, toolCount: 1 }),
  ];
}

function snapshot(): AcpmuxSnapshot {
  const base = chat(leosRows(), {
    title: "coordinator",
    sessions: [
      session({ sessionId: "gallery-session", title: "coordinator" }),
      session({
        sessionId: "s-protocol",
        title: "protocol-tidy",
        harness: "codex",
        host: "lane-5",
        hostKind: undefined,
      }),
      session({
        sessionId: "s-throughput",
        title: "ws-check-throughput",
        harness: "codex",
        host: "lane-4",
        hostKind: undefined,
      }),
    ],
  });
  return { ...base, summary: { ...base.summary!, family: "claude" } };
}

/// Opens every "Worked for" line, as Leo's first capture.
const openWorked: Play = async (ctx) => {
  for (let index = 0; index < 4; index += 1) {
    const closed = [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked[aria-expanded='false']")][0];
    if (!closed) return;
    closed.click();
    await ctx.waitFor(() => closed.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

/// Opens every Worked for, then every folded run in them, so each received line, the script and
/// "Sent to" draw on their own rows.
const openRuns: Play = async (ctx) => {
  await openWorked(ctx);
  for (let index = 0; index < 6; index += 1) {
    const closed = [...ctx.document.querySelectorAll<HTMLElement>(".cv-tool.is-run[aria-expanded='false']")][0];
    if (!closed) return;
    closed.click();
    await ctx.waitFor(() => closed.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

/// A density candidate laid over the shipped tokens (gallery only).
const density =
  (metric: RowMetric): Play =>
  async (ctx) => {
    const style = ctx.document.createElement("style");
    style.textContent = `:root {
      --cv-tool-row-height: ${metric.height}px;
      --cv-row-font-size: ${metric.font}px;
      --cv-row-chip-height: ${metric.chip}px;
      --cv-row-glyph: ${metric.glyph}px;
      --cv-worked-rule-above: ${metric.ruleAbove}px;
      --cv-worked-rule-below: ${metric.ruleBelow}px;
    }`;
    ctx.document.head.append(style);
    await openRuns(ctx);
  };

const variant = (note: string, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: snapshot(),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.activity-row-density",
  title: "Activity row density: one shared row metric",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/rowMetric.ts", "agent-session/acpmux/conversation/conversation.css"],
  variants: {
    expanded: variant("The coordinator chat with its Worked for sections open and tool runs folded.", openWorked),
    folded: variant("The same chat with the Worked for lines folded."),
    "runs-open": variant(
      "The same chat with its Worked for sections and tool runs open, showing the received messages, script and sent message.",
      openRuns,
    ),
    ...Object.fromEntries(
      Object.entries(ROW_METRIC_VARIANTS).map(([name, metric]) => [
        `density-${name}`,
        variant(
          `${metric.note} Rows ${metric.height}px, text ${metric.font}px, chips ${metric.chip}px, glyphs ${metric.glyph}px. The Worked for divider has ${metric.ruleAbove}px above and ${metric.ruleBelow}px below.`,
          density(metric),
        ),
      ]),
    ),
  },
});

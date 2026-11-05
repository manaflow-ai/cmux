// l10n-allow-file: gallery fixtures (sample lane names and messages), not shipped UI.
// Other agents' messages next to each other in a turn read as one row, "Received N messages" (Leo,
// 2026-11-02, on a turn of "3 inbox threads <session names…>", "Received 2 messages" and "2 inbox
// threads <session names…>" stacked: "can't we simply just display most of these as recieved x
// messages and all of them get revealed then we can expand the messages"). N counts messages; at
// rest no session names show (the senders' short names are its hover). Opened (level 1), every
// message is its own received line, the sender's mark in the tool rows' icon column and its name on
// the head's text column, with no indent (Leo, 2026-11-02: "why bother indenting here"); a message
// opened (level 2) shows its whole text. Drawn through the real transcript (turns.ts,
// laneNoticeBatches.ts `projectInboxRows`, LaneNoticeBatch.tsx), shaped like his screenshot: a
// notice of three threads, two messages that came in while its turn ran, and a notice of two.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "./incomingMessage";
import { inboxText } from "./inboxNotice";

type Sender = { name: string; session: string; harness: string };
const SENDERS: Sender[] = [
  { name: "build-box-11/nightly-rollback", session: "s-rollback", harness: "codex" },
  { name: "lane-box-1/opus-session-info", session: "s-session-info", harness: "claude" },
  { name: "lane-box-1/grid-pitch", session: "s-grid", harness: "claude" },
  { name: "lane-box-3/picker-polish", session: "s-picker", harness: "codex" },
  { name: "lane-box-4/rail-speed", session: "s-rail", harness: "claude" },
  { name: "build-box-02/base-red-watch-quiet", session: "s-base-red", harness: "codex" },
  { name: "lane-box-1/ux-owner", session: "s-ux", harness: "claude" },
];
const TEXT: Record<string, string> = {
  "s-rollback":
    "Rolled the nightly back to 6d9ae71; the 21:00 cut published.\n\nThe bad head was #2231's webview bundle. I left the revert PR open for its owner.",
  "s-session-info": "Session Info header lands at e34ce27, one icon column for every row.",
  "s-grid": "Row pitch is 22px on every one-line row now; #2210 is SHIP at 9c41a07.",
  "s-picker": "Picker polish is up for review as #2214.",
  "s-rail": "Rail scroll is 4ms per frame on the long fixture, down from 19ms.",
  "s-base-red": "Base is green again since 23:40; the watch is quiet.",
  "s-ux": "Took the transcript spacing asks; first PR goes up within the hour.",
};

/// An inbox notice as acpmux sends it (hub/inbox.rs `render`): one thread per sender.
function notice(senders: Sender[], minutes: number) {
  const threads = senders.map((sender, index) => ({
    threadId: `from:${sender.name}`,
    label: "",
    new: 1,
    from: [sender.name],
    fromSession: sender.session,
    fromHarness: sender.harness,
    promptIds: [`p-received-${minutes}-${index}`],
    blocker: false,
    preview: TEXT[sender.session]!.split("\n")[0]!,
    messages: [{ from: sender.name, promptId: `p-received-${minutes}-${index}`, text: TEXT[sender.session]! }],
  }));
  const text = [
    `[inbox] New messages from other agents in ${threads.length} threads.`,
    ...threads.map((t) => `- 1 new from ${t.from[0]}: ${t.preview} (thread ${t.threadId})`),
  ].join("\n");
  const incoming = incomingPrompt(text, {
    client: "acpmux",
    _meta: { provenance: { kind: "inbox_notice", noticeId: `notice-received-${minutes}`, threads } },
  });
  return incoming?.kind === "inbox"
    ? user(inboxText(incoming.notice), minutes, { incoming, untyped: true })
    : user(text, minutes);
}

/// Another agent's message that came in while the turn ran (a steer into it).
const received = (sender: Sender, minutes: number) =>
  user("", minutes, {
    continues: true,
    untyped: true,
    incoming: {
      kind: "message",
      message: {
        name: sender.name,
        sessionId: sender.session,
        harness: sender.harness,
        text: TEXT[sender.session]!,
        raw: TEXT[sender.session]!,
      },
    },
  });

function snapshot() {
  return chat(
    [
      user("Watch tonight's nightly and tell me when the lanes report back.", 9),
      assistant("Watching; I'll gather what the lanes send.", 8.8),
      summary(8.7, { status: "completed", durationMs: 12_000, toolCount: 0 }),
      notice(SENDERS.slice(0, 3), 6),
      received(SENDERS[3]!, 5.5),
      received(SENDERS[4]!, 5),
      notice(SENDERS.slice(5), 4),
      assistant("The nightly is back on 6d9ae71 and base is green; #2210 and #2214 are next.", 3.5),
      summary(3.4, { status: "completed", durationMs: 30_000, toolCount: 0 }),
    ],
    {
      title: "nightly-coordinator",
      sessions: [
        session({ sessionId: SESSION_ID, title: "nightly-coordinator", name: "nightly-coordinator" }),
        ...SENDERS.map((sender) =>
          session({ sessionId: sender.session, title: sender.name, name: sender.name, harness: sender.harness }),
        ),
      ],
    },
  );
}

const HEAD = ".cv-lane-batch[data-kind='inbox'] .cv-lane-batch__toggle";
const LINE = ".cv-lane-batch__body .cv-received .cv-disclosure__toggle";

/// Opens the "Received N messages" row (level 1).
const openRow: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(HEAD), { capMs: 10_000 });
  if (ctx.document.querySelector(HEAD)?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: HEAD });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-lane-batch__body .cv-received").length >= 7, {
    capMs: 10_000,
  });
};

/// Opens the row, then its first message (level 2).
const openMessage: Play = async (ctx) => {
  await openRow(ctx);
  if (ctx.document.querySelector(LINE)?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: LINE });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-lane-batch__body .cv-received__text"), { capMs: 10_000 });
};

const variants: Record<string, AgentPaneVariant> = {
  collapsed: {
    note: 'Selected default: a notice of three threads, two messages that came in while its turn ran and a notice of two are one row, "Received 7 messages", closed. No session names at rest; the senders\' short names are its hover.',
    snapshot: snapshot(),
  },
  "level-1": {
    note: "The row opened: every message on its own line, the sender (its mark in the tool rows' icon column, its name on the head's text column, no indent) and the message's first line.",
    snapshot: snapshot(),
    play: openRow,
  },
  "level-2": {
    note: "One message opened: its whole text under its line.",
    snapshot: snapshot(),
    play: openMessage,
  },
};

export default agentPaneEntry({
  id: "agent-pane.received-messages",
  title: "Received messages",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/LaneNoticeBatch.tsx",
    "agent-session/acpmux/conversation/LaneNoticeBatch.css",
    "agent-session/acpmux/conversation/laneNoticeBatches.ts",
    "agent-session/acpmux/conversation/messageRuns.ts",
  ],
  variants,
});

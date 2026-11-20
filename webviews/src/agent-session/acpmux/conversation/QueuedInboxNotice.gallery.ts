// l10n-allow-file: gallery fixtures (sample agent names and messages), not shipped UI.
// acpmux's inbox notice waiting in the queue behind a running turn (hub/inbox.rs, provenance
// `inbox_notice`). `before`: the notice as the composer's queue drew it, the agent's instruction text
// as one of the person's queued prompts with Steer, a trash can and ⋯ (Leo, 2026-11-03: "have it be
// rendered differently than just a regular queued message. we don't really wanna be cancelling agent
// back and forth messages 99% of the time"). The others: it joins the one group of waiting messages
// at the transcript's end (PendingMessagesCard.tsx), "N messages from M sessions" with the senders,
// the same row the delivered notice draws, its threads under it, Send now in the first line's ⋯ and
// no Dismiss. The `look-*` versions are inboxNoticeLook.ts's. Names and messages are made up.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, assistant, chat, session, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "./incomingMessage";
import type { AcpmuxSnapshot } from "../model";

type Message = { from: string; text: string; blocker?: boolean };
type Thread = { threadId: string; label: string; messages: Message[] };

const SENDERS: Record<string, string> = {
  "grid-lane": "s-grid",
  "picker-lane": "s-picker",
  "review-box": "s-review",
};

const THREADS: Thread[] = [
  {
    threadId: "from:grid-lane/pr:2210",
    label: "#2210",
    messages: [
      { from: "grid-lane", text: "#2210 is up: the grid reserves its height before images load." },
      { from: "grid-lane", text: "Review passed at e34ce27; landing it now." },
    ],
  },
  {
    threadId: "topic:picker plan",
    label: '"picker plan"',
    messages: [
      {
        from: "picker-lane",
        blocker: true,
        text: "Which branch should the picker polish go on, feat-cmux-next or the stack under #2214?",
      },
    ],
  },
  {
    threadId: "from:review-box/pr:2214",
    label: "#2214",
    messages: [{ from: "review-box", text: "SHIP at 9c41a07: the menu opens on the click and nothing fades in." }],
  },
  {
    threadId: "topic:rail",
    label: '"rail"',
    messages: [
      { from: "picker-lane", text: "The rail's band now reaches the last tick." },
      { from: "review-box", text: "Checked it in the gallery at both widths; it does." },
    ],
  },
];

let prompt = 0;

/// The notice's `queued` record as hub/queue.rs writes it: its text for the agent, its threads in
/// its provenance, no `fromAgent`.
function record(threads: Thread[]) {
  const n = threads.length;
  const lines = [
    `[inbox] New messages from other agents in ${n} thread${n === 1 ? "" : "s"}. Read one whole with inbox_read (its thread id), answer in it with inbox_reply, or leave it for later.`,
  ];
  const parts = threads.map((thread) => {
    const from = [...new Set(thread.messages.map((m) => m.from))];
    const blocker = thread.messages.some((m) => m.blocker);
    const newest = thread.messages.at(-1)!;
    lines.push(
      `- ${blocker ? "[blocker] " : ""}${thread.messages.length} new in ${thread.label} from ${from.join(", ")}: ${newest.text} (thread ${thread.threadId})`,
    );
    return {
      threadId: thread.threadId,
      label: thread.label,
      new: thread.messages.length,
      from,
      fromSession: SENDERS[newest.from],
      promptIds: thread.messages.map(() => `m-${++prompt}`),
      blocker,
      preview: newest.text,
      messages: thread.messages.map((m) => ({ from: m.from, text: m.text })),
    };
  });
  const text = lines.join("\n");
  return {
    text,
    client: "acpmux",
    promptId: "inbox-notice-1",
    _meta: { provenance: { kind: "inbox_notice", noticeId: "inbox-notice-1", threads: parts } },
  };
}

/// The queue: the notice (as the pane reads its record; `before`, as it read it until now), and the
/// person's own prompt after it, which stays a composer row.
function queue(before: boolean): AcpmuxSnapshot["queue"] {
  const notice = record(THREADS);
  const incoming = before ? undefined : incomingPrompt(notice.text, notice);
  const inbox = incoming?.kind === "inbox" ? incoming.notice : undefined;
  return [
    { id: "inbox-notice-1", prompt: notice.text, ...(inbox ? { inbox } : {}) },
    { id: "p-own", prompt: "Then rebase the picker stack onto feat-cmux-next." },
  ];
}

function snapshot(before = false) {
  return chat(
    [
      user("Hand the polish lanes their briefs and land what comes back reviewed.", 12),
      assistant("Landing #2210 once its review comes back…", 3, { streaming: true }),
    ],
    {
      title: "polish-coordinator",
      isWorking: true,
      queue: queue(before),
      sessions: [
        session({ sessionId: SESSION_ID, title: "polish-coordinator", name: "polish-coordinator" }),
        session({ sessionId: "s-grid", title: "grid-lane", name: "grid-lane", harness: "claude" }),
        session({ sessionId: "s-picker", title: "picker-lane", name: "picker-lane", harness: "codex" }),
        session({ sessionId: "s-review", title: "review-box", name: "review-box", harness: "codex" }),
      ],
    },
  );
}

/// Opens the waiting group.
const openGroup: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-pending__toggle"));
  ctx.document.querySelector<HTMLButtonElement>(".cv-pending__toggle")?.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-pending__body"));
};

export default agentPaneEntry({
  id: "agent-pane.queued-inbox-notice",
  title: "Inbox notice waiting behind a turn",
  area: "Agent pane",
  height: 460,
  covers: [
    "agent-session/acpmux/conversation/queuedMessages.ts",
    "agent-session/acpmux/conversation/PendingMessagesCard.tsx",
  ],
  variants: {
    before: {
      note: "Before: the notice as one of the person's queued prompts, its text for the agent, with Steer, a trash can and ⋯.",
      snapshot: snapshot(true),
    },
    waiting: {
      note: "The pick: one row at the transcript's end, \"N messages from M sessions\" and the senders, as a delivered notice draws; the person's own prompt stays in the queue. It goes in when the turn ends.",
      snapshot: snapshot(),
    },
    "waiting-open": {
      note: "Opened: each thread's line (its sender, label and first line), each opening its thread; Send now in the first line's ⋯, no Dismiss.",
      snapshot: snapshot(),
      play: openGroup,
    },
    "look-chevron": {
      note: "Gallery version (theme inboxNoticeLook group-chevron): the group's chevron always shown.",
      theme: { inboxNoticeLook: "group-chevron" },
      snapshot: snapshot(),
    },
    "look-count": {
      note: "Gallery version (theme inboxNoticeLook group-count): the count alone; the senders in its tooltip.",
      theme: { inboxNoticeLook: "group-count" },
      snapshot: snapshot(),
    },
  },
});

// l10n-allow-file: gallery fixtures (sample agent names and messages), not shipped UI.
// acpmux's inbox notice (hub/inbox.rs, provenance `inbox_notice`) in the transcript: each thread is
// another agent's received line (the sender, the thread's label, the newest message's first line,
// "+N more"), and two or more threads fold under one line, "N messages from M sessions" (Leo,
// 2026-10-31, on the notice drawn as the person's bubbles: "isn't this rendered pretty terribly? why
// do we have this like this? why is there so much additional text?"). `before`: the notice as the
// pane drew it, its text for the agent in the person's bubble. The `look-*` versions beside the
// default are inboxNoticeLook.ts's (`theme.inboxNoticeLook`). Names and messages are made up.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, activity, assistant, chat, session, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "./incomingMessage";
import { inboxText } from "./inboxNotice";

type Message = { from: string; text: string; blocker?: boolean };
type Thread = { threadId: string; label: string; messages: Message[]; fromSession?: string };

const SENDERS: Record<string, string> = {
  "ao-log-bloat": "s-log-bloat",
  "grid-lane": "s-grid",
  "picker-lane": "s-picker",
  "review-box": "s-review",
};

const BLOAT: Thread = {
  threadId: "from:ao-log-bloat/pr:28564",
  label: "#28564",
  messages: [
    {
      from: "ao-log-bloat",
      blocker: true,
      text: "Broker refusal on #28564. The broker's GitHub returned 403 on the land, so I couldn't merge it.\n\nThe review is SHIP at 3b01de6 and the only red is `release-notary`, red on base too. Can you land it from a host with a token?",
    },
  ],
};
const GRID: Thread = {
  threadId: "pr:2210",
  label: "#2210",
  messages: [
    { from: "grid-lane", text: "#2210 is up: the grid reserves its height before images load." },
    { from: "grid-lane", text: "Review passed at e34ce27; landing it now." },
  ],
};
const PLAN: Thread = {
  threadId: "topic:picker plan",
  label: '"picker plan"',
  messages: [
    {
      from: "picker-lane",
      text: "Which branch should the picker polish go on, feat-cmux-next or the stack under #2214?",
    },
  ],
};
const REVIEW: Thread = {
  threadId: "from:review-box/pr:2214",
  label: "#2214",
  messages: [{ from: "review-box", text: "SHIP at 9c41a07: the menu opens on the click and nothing fades in." }],
};
const FYI: Thread = {
  threadId: "from:grid-lane",
  label: "messages",
  messages: [{ from: "grid-lane", text: "FYI the nightly published 18 minutes after #2210 landed." }],
};
const RAIL: Thread = {
  threadId: "topic:rail",
  label: '"rail"',
  messages: [
    { from: "picker-lane", text: "The rail's band now reaches the last tick." },
    { from: "review-box", text: "Checked it in the gallery at both widths; it does." },
    { from: "picker-lane", text: "Merged as #2231." },
  ],
};

let prompt = 0;

/// A notice as acpmux sends it (hub/inbox.rs `render`): its text for the agent and its `threads`.
function noticeOf(threads: Thread[]) {
  const lines = [
    `[inbox] New messages from other agents in ${threads.length} thread${threads.length === 1 ? "" : "s"}.`,
  ];
  const parts = threads.map((thread) => {
    const from = [...new Set(thread.messages.map((m) => m.from))];
    const blocker = thread.messages.some((m) => m.blocker);
    const newest = thread.messages.at(-1)!;
    const head = `${blocker ? "[blocker] " : ""}${thread.messages.length} new in ${thread.label} from ${from.join(", ")}`;
    if (thread.messages.length === 1 && !newest.text.includes("\n"))
      lines.push(`- ${head}: ${newest.text} (thread ${thread.threadId})`);
    else {
      lines.push(`- ${head} (thread ${thread.threadId}):`);
      for (const m of thread.messages) for (const line of m.text.split("\n")) lines.push(`  > ${line}`.trimEnd());
    }
    return {
      threadId: thread.threadId,
      label: thread.label,
      new: thread.messages.length,
      from,
      fromSession: SENDERS[newest.from],
      promptIds: thread.messages.map(() => `p-${++prompt}`),
      blocker,
      preview: newest.text.split("\n")[0],
      messages: thread.messages.map((m) => ({ from: m.from, text: m.text })),
    };
  });
  return {
    text: lines.join("\n"),
    provenance: { kind: "inbox_notice", noticeId: `inbox-notice-${prompt}`, threads: parts },
  };
}

/// The notice's text as acpmux wrote it before this change: the instruction sentence, then one line
/// per thread with the newest message's first line cut to 120 characters.
function oldText(threads: Thread[]): string {
  const n = threads.length;
  const lines = [
    `[inbox] New messages from other agents in ${n} thread${n === 1 ? "" : "s"}. They need no turn of your own: read a thread whole with the inbox_read tool (its thread id), answer in it with inbox_reply, or leave it for later.`,
  ];
  for (const thread of threads) {
    const from = [...new Set(thread.messages.map((m) => m.from))].join(", ");
    const tag = thread.messages.some((m) => m.blocker) ? "[blocker] " : "";
    const first = thread.messages.at(-1)!.text.split("\n")[0]!;
    const line = first.length > 120 ? `${first.slice(0, 120)}…` : first;
    lines.push(
      `- ${tag}${thread.messages.length} new in ${thread.label} from ${from}: ${line} (thread ${thread.threadId})`,
    );
  }
  return lines.join("\n");
}

/// The notice's row as direct.ts reads its recorded `user_message`; `before`, as the pane drew it.
function notice(threads: Thread[], minutes: number, before = false) {
  const { text, provenance } = noticeOf(threads);
  if (before) return user(oldText(threads), minutes);
  const incoming = incomingPrompt(text, { client: "acpmux", _meta: { provenance } });
  return incoming?.kind === "inbox"
    ? user(inboxText(incoming.notice), minutes, { incoming, untyped: true })
    : user(text, minutes);
}

/// A coordinator's chat that hears from its lanes: `notices`, each a list of threads, after its turn.
function snapshot(notices: Thread[][], before = false) {
  return chat(
    [
      user("Hand the three polish lanes their briefs and land what comes back reviewed.", 12),
      assistant("Sent the briefs to grid-lane, picker-lane and ao-log-bloat; I'll land each as its review passes.", 11),
      summary(11, { status: "completed" }),
      ...notices.map((threads, at) => notice(threads, 3 - at * 0.5, before)),
    ],
    {
      title: "polish-coordinator",
      sessions: [
        session({ sessionId: SESSION_ID, title: "polish-coordinator", name: "polish-coordinator" }),
        session({ sessionId: "s-log-bloat", title: "ao-log-bloat", name: "ao-log-bloat", harness: "codex" }),
        session({ sessionId: "s-grid", title: "grid-lane", name: "grid-lane" }),
        session({ sessionId: "s-picker", title: "picker-lane", name: "picker-lane", harness: "codex" }),
        session({ sessionId: "s-review", title: "review-box", name: "review-box", harness: "codex" }),
      ],
    },
  );
}

/// A sender no chat here lists, named like another harness (a Codex lane called `claude-…`): its
/// line draws the neutral agent glyph, never a mark guessed from the name.
const UNLISTED: Thread = {
  threadId: "from:claude-mesh-lane/pr:5805",
  label: "#5805",
  messages: [{ from: "claude-mesh-lane", text: "HQ#5805 at b070cf5 opened its verification issue." }],
};

/// Two messages from one session that wait for the agent's turn to end (PendingMessagesCard.tsx):
/// "2 messages from 1 session", the case Leo named.
const WAITING = [
  "Review passed at e34ce27; landing #2210 now.",
  "Landed #2210; the nightly picks it up in its next run.",
].map((text, index) => ({
  id: `w${index + 1}`,
  prompt: text,
  message: { name: "grid-lane", sessionId: "s-grid", harness: "claude", text, raw: text },
}));

/// Inbox rows among tool rows, as a coordinator's chat draws them: a run of commands, one thread's
/// line, a delivered group of one sender's threads, one of several senders', and the messages that
/// wait (Leo, 2026-11-01: "i wanted this to be left aligned with the other tool calls" and "let's
/// just make this look better"). Every group's head is a tool row (MessageGroupHead.tsx).
/// inbox-row-icon-column.test.ts measures it.
function amongTools() {
  const run = (minutes: number) =>
    activity(
      [
        tool("Run", "execute", "completed", {
          command: "gh pr checks 2210",
          output: "web / react-apps-base-check pass\n",
        }),
        tool("Run", "execute", "completed", { command: "git log --oneline -1", output: "6d9ae71 base autofix\n" }),
      ],
      minutes,
    );
  return chat(
    [
      user("Hand the three polish lanes their briefs and land what comes back reviewed.", 12),
      run(11),
      notice([BLOAT], 10),
      run(9),
      notice([UNLISTED], 8.5),
      run(8),
      notice([GRID, FYI], 7),
      run(6),
      notice([PLAN, REVIEW, RAIL], 5),
      run(4),
      assistant("Landing #2210 once its review comes back…", 3, { streaming: true }),
    ],
    {
      title: "polish-coordinator",
      isWorking: true,
      queue: WAITING,
      sessions: [
        session({ sessionId: SESSION_ID, title: "polish-coordinator", name: "polish-coordinator" }),
        session({ sessionId: "s-log-bloat", title: "ao-log-bloat", name: "ao-log-bloat", harness: "codex" }),
        session({ sessionId: "s-grid", title: "grid-lane", name: "grid-lane", harness: "claude" }),
        session({ sessionId: "s-picker", title: "picker-lane", name: "picker-lane", harness: "codex" }),
        session({ sessionId: "s-review", title: "review-box", name: "review-box", harness: "codex" }),
      ],
    },
  );
}

const ONE = [[BLOAT]];
const THREE = [[BLOAT, PLAN, GRID]];
// Leo's case: notices in a row, each its own prompt; six threads in all.
const SIX = [
  [BLOAT, GRID],
  [PLAN, REVIEW],
  [FYI, RAIL],
];

/// Opens the delivered inbox batch (when there is one) and the first received line. Inbox
/// deliveries now use the same flat lane-notice projection as the transcript, so a notice's
/// own InboxNoticeCard selectors are only present for the legacy singleton shape.
const openFirst: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-lane-batch__toggle, .cv-received .cv-disclosure__toggle"));
  ctx.document.querySelector<HTMLButtonElement>(".cv-lane-batch__toggle")?.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-received .cv-disclosure__toggle"));
  ctx.document.querySelector<HTMLButtonElement>(".cv-received .cv-disclosure__toggle")?.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-received__text"));
};
/// Opens every delivered batch and the last received line, which is the three-message rail thread
/// in the fixture after inbox flattening.
const openRail: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-lane-batch__toggle, .cv-received .cv-disclosure__toggle"));
  for (const batch of ctx.document.querySelectorAll<HTMLButtonElement>(".cv-lane-batch__toggle")) batch.click();
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-received .cv-disclosure__toggle").length >= 3);
  const lines = ctx.document.querySelectorAll<HTMLButtonElement>(".cv-received .cv-disclosure__toggle");
  lines[lines.length - 1]?.click();
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-received__text").length >= 1);
};

export default agentPaneEntry({
  id: "agent-pane.inbox-notice",
  title: "Inbox notices from other agents",
  area: "Agent pane",
  height: 460,
  covers: [
    "agent-session/acpmux/conversation/InboxNoticeCard.tsx",
    "agent-session/acpmux/conversation/InboxNoticeCard.css",
    "agent-session/acpmux/conversation/MessageGroupHead.tsx",
    "agent-session/acpmux/conversation/MessageGroupHead.css",
    "agent-session/acpmux/conversation/LaneNoticeBatch.tsx",
    "agent-session/acpmux/conversation/PendingMessagesCard.tsx",
    "agent-session/acpmux/conversation/inboxNotice.ts",
    "agent-session/acpmux/conversation/incomingMessage.ts",
  ],
  variants: {
    "icon-column": {
      note: "Inbox rows among tool rows: one thread's line, a delivered group of one sender (its harness mark), one of several (the messages glyph), and the messages that wait (\"2 messages from 1 session\"). Every row's glyph sits in the tool rows' icon column, its words start where theirs do, and a group's head is a tool row, their height, gap and type, its chevron shown on hover. A sender no chat lists draws the neutral agent glyph.",
      snapshot: amongTools(),
    },
    "icon-column-look-chevron": {
      note: "Gallery version (theme inboxNoticeLook group-chevron): the group's chevron always shown.",
      theme: { inboxNoticeLook: "group-chevron" },
      snapshot: amongTools(),
    },
    "icon-column-look-count": {
      note: "Gallery version (theme inboxNoticeLook group-count): the count alone; the senders in its tooltip.",
      theme: { inboxNoticeLook: "group-count" },
      snapshot: amongTools(),
    },
    "icon-column-open": {
      note: "The same, the group of several opened: its threads' lines under it.",
      snapshot: amongTools(),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-message-group__head").length >= 2);
        ctx.document.querySelectorAll<HTMLButtonElement>(".cv-message-group__head")[1]?.click();
        await ctx.waitFor(() => ctx.document.querySelector(".cv-lane-batch__body .cv-received"));
      },
    },
    "before-six": {
      note: "Before: three notices in a row, as acpmux wrote them and the pane drew them: each its text for the agent in the person's bubble.",
      snapshot: snapshot(SIX, true),
    },
    one: {
      note: "One thread: the sender's received line, its label and the message's first line; nothing of the agent's text.",
      snapshot: snapshot(ONE),
    },
    "one-open": {
      note: "One thread, opened: the whole message under the line.",
      snapshot: snapshot(ONE),
      play: openFirst,
    },
    three: {
      note: 'Three threads: one line, "4 messages from 3 sessions" and the senders.',
      snapshot: snapshot(THREE),
    },
    "three-open": {
      note: "Three threads, opened: a received line per thread, the first opened.",
      snapshot: snapshot(THREE),
      play: openFirst,
    },
    six: {
      note: "Three notices in a row (six threads) fold into one line.",
      snapshot: snapshot(SIX),
    },
    "six-open": {
      note: "Six threads, opened, the thread of three messages opened: each message under its sender.",
      snapshot: snapshot(SIX),
      play: openRail,
    },
    "look-lines-three": {
      note: "Gallery version (theme inboxNoticeLook lines): a received line per thread, no head.",
      theme: { inboxNoticeLook: "lines" },
      snapshot: snapshot(THREE),
    },
    "look-lines-six": {
      note: "Gallery version (theme inboxNoticeLook lines), six threads.",
      theme: { inboxNoticeLook: "lines" },
      snapshot: snapshot(SIX),
    },
    "look-card-three": {
      note: "Gallery version (theme inboxNoticeLook card): the threads' lines in one quiet bordered card.",
      theme: { inboxNoticeLook: "card" },
      snapshot: snapshot(THREE),
    },
    "look-card-six": {
      note: "Gallery version (theme inboxNoticeLook card), six threads.",
      theme: { inboxNoticeLook: "card" },
      snapshot: snapshot(SIX),
    },
  },
});

// l10n-allow-file: gallery fixtures (sample relayed messages), not shipped UI.
// A lane VM's message the lane-gh broker relayed (`lane-gh send SESSION`): the broker labels it
// for the agent, `[message N from VM/LANE (an agent, not Leo), relayed by the lane-gh broker; its
// text ends at "[end of message N]"]` … `[end of message N]`, and the pane drew that label as the
// message (Leo, 2026-11-05: "It probably shouldn't be displaying it in that kind of raw way. Like
// we don't need to render it like this, in either here nor the iOS thing."). The line now draws
// its sender's card with the message as Markdown; the label stays in the prompt behind Details
// (relayEnvelope.ts). Each row runs the recorded text through incomingPrompt, so the merge-base's
// gallery shows the pane as it drew these before.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "./incomingMessage";
import { inboxText } from "./inboxNotice";

const SENDER = "gcp-codex-swarm-11/claude-3";

/// The broker's label around `body`, with the nonce `id` (from a transcript of 2026-11-05).
function relayed(body: string, id = "4f4d68ff", from = SENDER) {
  return [
    `[message ${id} from ${from} (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message ${id}]"]`,
    body,
    `[end of message ${id}]`,
  ].join("\n");
}

const REPORT = [
  "**#36125 is green** at `64d6b1b`; the exact-head review is a SHIP.",
  "",
  "- acpmux lists other machines' sessions through the send relay",
  "- the cross-host audit names sender and target, never the text",
  "",
  "Landing it pinned once the base-only reds are confirmed.",
].join("\n");

/// The message as direct.ts reads its recorded `user_message`: the broker's `acpmux send --no-wait
/// --from VM/LANE`, which acpmux records as a named sender's.
function relay(text: string, minutes: number) {
  const provenance = { kind: "agent_message", from: "fromAgent", fromName: SENDER, to: SESSION_ID };
  const incoming = incomingPrompt(text, { client: "acpmux-cli#01a1@cosmic-gray", _meta: { provenance } });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { incoming, resend: text, untyped: true })
    : user(text, minutes);
}

/// Three messages that waited for a busy chat and went in as one turn (acpmux hub/digest.rs), two
/// of them relayed by the broker.
function digest(minutes: number) {
  const parts = [
    { from: SENDER, text: relayed("Rebased on `feat-cmux-next`; CI is running.", "a1b2c3d4") },
    { from: "claude-sr2-coord", text: "Take the iOS half next; the parser is shared." },
    {
      from: "gcp-codex-swarm-4/codex-1",
      text: relayed("**Review:** SHIP at `64d6b1b`.", "9e8f7a6b", "gcp-codex-swarm-4/codex-1"),
    },
  ];
  const text = [
    `${parts.length} messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.`,
    ...parts.flatMap((part, index) => [
      "",
      `[agent message ${index + 1} of ${parts.length}] from ${part.from}`,
      "",
      part.text,
    ]),
  ].join("\n");
  const provenance = { kind: "agent_digest", messages: parts.map((part) => ({ from: part.from })) };
  const incoming = incomingPrompt(text, { client: "acpmux", _meta: { provenance } });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { incoming, resend: text, untyped: true })
    : user(text, minutes);
}

/// The inbox's notice of one thread whose new message the broker relayed.
function inbox(minutes: number) {
  const message = relayed(REPORT);
  const provenance = {
    kind: "inbox_notice",
    noticeId: "inbox-notice-relay",
    threads: [
      {
        threadId: `from:${SENDER}`,
        label: "messages",
        from: [SENDER],
        new: 1,
        preview: message.split("\n")[0],
        messages: [{ from: SENDER, text: message }],
      },
    ],
  };
  const text = `[inbox] New messages from other agents in 1 thread.\n- 1 new in messages from ${SENDER}: ${message.split("\n")[0]} (thread from:${SENDER})`;
  const incoming = incomingPrompt(text, { client: "acpmux", _meta: { provenance } });
  return incoming?.kind === "inbox"
    ? user(inboxText(incoming.notice), minutes, { incoming, untyped: true })
    : user(text, minutes);
}

const RECEIVED_LINE = ".cv-received__line";

/// Opens the line, then its Details: the prompt as the agent got it, label and all.
const openDetails: Play = async (ctx) => {
  await ctx.click({ selector: RECEIVED_LINE });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-received__more"));
  await ctx.click({ selector: ".cv-received__more" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-received__details pre"));
};

const openLine: Play = async (ctx) => {
  await ctx.click({ selector: RECEIVED_LINE });
  await ctx.waitFor(() => ctx.document.querySelector(`${RECEIVED_LINE}[aria-expanded="true"]`));
};

function snapshot(last: ReturnType<typeof user>) {
  return chat(
    [
      user("Have the swarm lane land #36125 and report here.", 9),
      assistant("Sent the order to claude-3 on gcp-codex-swarm-11.", 8.5),
      summary(8.5, { status: "completed" }),
      last,
    ],
    {
      title: "claude-sr2-coord",
      sessions: [session({ sessionId: SESSION_ID, title: "claude-sr2-coord", name: "claude-sr2-coord" })],
    },
  );
}

export default agentPaneEntry({
  id: "agent-pane.relayed-message",
  title: "A message the lane-gh broker relayed",
  area: "Agent pane",
  height: 460,
  covers: [
    "agent-session/acpmux/conversation/relayEnvelope.ts",
    "agent-session/acpmux/conversation/incomingMessage.ts",
    "agent-session/acpmux/conversation/inboxNotice.ts",
  ],
  variants: {
    line: {
      note: "A lane VM's report through the broker: its sender's line, the message's first words, no label.",
      snapshot: snapshot(relay(relayed(REPORT), 3)),
    },
    open: {
      note: "The line opened: the whole message as Markdown.",
      snapshot: snapshot(relay(relayed(REPORT), 3)),
      play: openLine,
    },
    details: {
      note: 'Details holds the prompt as the agent got it: the broker\'s label with its nonce and "an agent, not Leo".',
      snapshot: snapshot(relay(relayed(REPORT), 3)),
      play: openDetails,
    },
    digest: {
      note: "Three messages that waited for a busy chat, two relayed: one card, each under its sender, no labels.",
      snapshot: snapshot(digest(3)),
      play: openLine,
    },
    inbox: {
      note: "The inbox's notice of a relayed message: the thread's line reads the message, not the label.",
      snapshot: snapshot(inbox(3)),
    },
  },
});

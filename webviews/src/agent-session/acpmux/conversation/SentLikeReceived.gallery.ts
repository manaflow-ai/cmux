// l10n-allow-file: gallery fixtures (sample commands, session names and messages), not shipped UI.
// A message this agent sent another one beside a message another agent sent it (ask-64e107ccf0;
// Leo, 2026-11-07, on a "Sent to" row whose Raw was open on a heavy Shell card under a received
// message: "Did we not fix this formatting yet? Um, like the raw thing? This is just weird. This, I
// mean, yeah, it's just not good, compared to the normal ones."). The send draws as the received
// line does (SentMessageLine.tsx): the mark, "Sent to", the recipient's chip and its machine, the
// first line muted, the chevron, then "queued". Opened, both are the same card; Raw is closed until
// asked for, and opened it is the call's plain command row. Compare the arms
// (`sent-message-look`: link, chevron, hover, plain).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { sentMessageLook } from "./sentMessageLook.experiment";

const RECEIVED =
  "Rebased acpmux-client-rust on feat-cmux-next; the reconnect test passes. Handing the lane back for the next item.";
const SENT =
  "coord: the old lane's handoff is yours now. Pick up the reconnect backoff where it stopped, and report when the PR is open.";

const received = user("", 6, {
  incoming: {
    kind: "message",
    message: {
      name: "dev-box/acpmux-client-rust",
      sessionId: "sub-acpmux-client-rust",
      text: RECEIVED,
      raw: RECEIVED,
      harness: "codex",
    },
  },
  untyped: true,
});

// Leo's call: an `acpmux send` to a lane on another machine, its output cut to the daemon's line.
const send = tool("acpmux send build-box/acpmux-client-rust-2 …", "execute", "completed", {
  command: `acpmux send build-box/acpmux-client-rust-2 '${SENT.replace("'", `'"'"'`)}' 2>&1|tail -1`,
  description: "Hand the lane to acpmux-client-rust-2",
  output: "queued (delivery 01a1b65e-7c1d-7e2a-9f00-3b5a2c1d0e9f)",
  exitCode: 0,
});

const snapshot = () =>
  chat(
    [
      user("Hand the old lane's work to the new client lane.", 7),
      received,
      activity([send], 5.8),
      assistant("Handed it over; the new lane has the handoff.", 5.5),
      summary(5.5, { status: "completed" }),
    ],
    { title: "coord" },
  );

/// The turn's work shows: its "Worked for" line opens when it is folded.
const drawn = async (ctx: PlayContext) => {
  const folded = ctx.document.querySelector<HTMLElement>(".cv-worked.is-toggle[aria-expanded=false]");
  if (folded) await ctx.click({ selector: ".cv-worked.is-toggle" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-sent-msg"));
};

/// Both messages open, the received one first, as Leo's capture shows them. A message already open
/// stays open, so the experiment's script can run after a variant's play.
const RECEIVED_TOGGLE = ".cv-received:not(.cv-sent-msg) .cv-agentmsg__toggle[aria-expanded=false]";
const SENT_TOGGLE = ".cv-sent-msg .cv-agentmsg__toggle[aria-expanded=false]";
const opened = async (ctx: PlayContext) => {
  await drawn(ctx);
  if (ctx.document.querySelector(RECEIVED_TOGGLE)) await ctx.click({ selector: RECEIVED_TOGGLE });
  if (ctx.document.querySelector(SENT_TOGGLE)) await ctx.click({ selector: SENT_TOGGLE });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-sent-msg .cv-received__text .cv-md"));
};

/// Then Raw: the call as its plain command row.
const rawOpen = async (ctx: PlayContext) => {
  await opened(ctx);
  await ctx.click({ selector: ".cv-sent-msg .cv-sent__raw > .cv-received__more" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-sent-msg .cv-sent__raw [data-tool-id]"));
};

export default agentPaneEntry({
  id: "agent-pane.sent-like-received",
  title: "Sent message like a received one",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: [
    "agent-session/acpmux/conversation/SentMessageLine.tsx",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
  ],
  keywords: ["sent", "send", "acpmux send", "raw", "received", "message", "agent message"],
  variants: {
    closed: {
      note: 'A received message, then the send: both one line, the mark, the other agent\'s chip and its machine, the first line muted; the send says "Sent to" and ends in "queued".',
      snapshot: snapshot(),
      play: drawn,
    },
    opened: {
      note: "Both opened: the same light card of the whole message; the send's Raw is a quiet link, closed.",
      snapshot: snapshot(),
      play: opened,
    },
    "raw-open": {
      note: "Raw opened: the call is its plain command row (Ran acpmux send …), never a Shell card inside the message.",
      snapshot: snapshot(),
      play: rawOpen,
    },
  },
  experiment: {
    definition: sentMessageLook,
    script: [
      { name: "Open both messages", run: opened },
      {
        name: "Open Raw",
        run: async (ctx) => {
          const raw = ".cv-sent-msg .cv-sent__raw > .cv-received__more[aria-expanded=false]";
          if (ctx.document.querySelector(raw)) await ctx.click({ selector: raw });
        },
      },
    ],
  },
});

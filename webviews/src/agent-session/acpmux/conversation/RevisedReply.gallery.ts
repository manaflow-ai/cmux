// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A reply the agent sent again after a Stop hook (design/revised-reply.md, RevisedReply.tsx). Leo,
// 2026-11-14, on the same "A few updates:" report drawn twice back to back: "why did u send this
// twice?". A Stop hook blocked the stop over one line and the agent sent the whole reply again;
// acpmux records the second as replacing the first (`message_superseded`, reason `stop_hook`), and
// the pane streams it into the first one's row. `recorded` replays that turn as acpmux records it
// through the pane's own client (fixtures/recordings/claude-stop-hook-resend.ndjson); its play
// checks one reply shows, the new one, and that Revised opens the first. Compare arms shows the
// `revised-reply-look` experiment's three marks.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { revisedReplyLook } from "./revisedReply.experiment";

const recording = {
  events: async () => (await import("../../../gallery/fixtures/recordings/claude-stop-hook-resend.ndjson?raw")).default,
  harness: "claude" as const,
};

const PROMPT = "Where are the three open items?";
const FIRST =
  "A few updates:\n\n- **Storage key:** the session making it restarted and is retrying the bucket step now.\n- **Reconnecting on its own:** the required check that failed was the helper's own bug, and it's fixed now.\n- **Restart numbers:** the chat settles 1.1 to 1.3 s after the first frame; the helper is taking the after numbers.";
const AGAIN =
  "A few updates:\n\n- **Storage key:** the session making it restarted and is retrying the bucket step now.\n- **Reconnecting on its own:** the helper pushed a change for the failed check; its checks have not passed yet, so that is still unconfirmed.\n- **Restart numbers:** the chat settles 1.1 to 1.3 s after the first frame; the helper is taking the after numbers.";
const REASON = "Your report calls something fixed with no evidence beside it. Rewrite only that sentence, briefly.";

const revisedTurn = () => [
  user(PROMPT, 3),
  assistant(AGAIN, 2.9, { id: "revised-reply", revisedFrom: { text: FIRST, reason: REASON } }),
  summary(2.8, { status: "completed", durationMs: 97_000 }),
];

/// One reply shows, the new one; Revised opens the first version under it.
const checkRevised = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-revised__toggle"));
  const body = ctx.document.body.textContent ?? "";
  if ((body.match(/A few updates:/g) ?? []).length !== 1) throw new Error("the reply is drawn more than once");
  if (!body.includes("still unconfirmed")) throw new Error("the new reply is not the one shown");
  if (body.includes("it's fixed now")) throw new Error("the first reply shows before Revised is opened");
  await ctx.click({ selector: ".cv-revised__toggle" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-revised__earlier"));
  if (!(ctx.document.querySelector(".cv-revised__earlier")?.textContent ?? "").includes("it's fixed now"))
    throw new Error("Revised does not open the first reply");
};

export default agentPaneEntry({
  id: "agent-pane.revised-reply",
  title: "Reply sent again after a Stop hook",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/RevisedReply.tsx",
    "agent-session/acpmux/rows/MessageRow.tsx",
    "agent-session/acpmux/direct.ts#reviseSupersededMessage",
  ],
  keywords: ["stop hook", "revised", "duplicate", "sent twice", "superseded"],
  variants: {
    recorded: {
      note: "The recorded turn: the reply, a Stop hook, the reply again with one line changed. One reply shows, the new one, with a muted Revised under it that opens the first.",
      snapshot: chat([], { harness: "claude", model: "claude-opus-5-5", title: "Open items" }),
      recording,
      play: checkRevised,
    },
    revised: {
      note: "At rest: the new reply in the first one's place and the muted Revised word.",
      snapshot: chat(revisedTurn(), { harness: "claude", title: "Open items" }),
    },
    "revised-open": {
      note: "Revised opened: the first version under the reply, in dim ink behind a rule.",
      snapshot: chat(revisedTurn(), { harness: "claude", title: "Open items" }),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-revised__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-revised__earlier"));
      },
    },
    revising: {
      note: "While the agent sends the reply again: the row keeps the first version whole (nothing below it moves) and says Revising…",
      snapshot: chat(
        [
          user(PROMPT, 3),
          assistant(AGAIN.slice(0, 40), 2.9, {
            id: "revised-reply",
            streaming: true,
            revisedFrom: { text: FIRST, reason: REASON },
          }),
        ],
        { harness: "claude", title: "Open items", isWorking: true },
      ),
    },
    before: {
      note: "Before (for comparison): both replies drawn back to back, as Leo saw them.",
      snapshot: chat(
        [user(PROMPT, 3), assistant(FIRST, 2.95), assistant(AGAIN, 2.9), summary(2.8, { status: "completed" })],
        {
          harness: "claude",
          title: "Open items",
        },
      ),
    },
  },
  experiment: {
    definition: revisedReplyLook,
    script: [{ name: "at rest", run: async () => {} }],
  },
});

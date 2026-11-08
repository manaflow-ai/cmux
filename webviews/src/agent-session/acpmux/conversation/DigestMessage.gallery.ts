// l10n-allow-file: gallery fixtures (sample commands, senders and pages), not shipped UI.
// Messages that waited for a busy chat and went in as one turn (acpmux hub/digest.rs `agent_digest`;
// incomingMessage.ts `digestRead`). Leo, 2026-11-07, on a closed line that read only "acpmux
// acpmux": "why was this blank?" The turn's text puts each message under its sender's bold name, and
// the line previewed that first name. Now a turn of notices alone draws as one notice row (the most
// severe notice's mark and title, every notice under it), and any other turn of several previews its
// first message's words. Each row runs the recorded text through incomingPrompt, so the merge-base's
// gallery shows the line as it drew before. Commands, names and numbers are made up.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "./incomingMessage";
import { noticeRowText } from "./agentNotice";

/// acpmux's notices of background commands that ended while the chat was busy (Leo's capture).
const FINISHED = [
  "[notice from acpmux] Background command finished: wt new manaflow-ai/cmux lane/digest-notice-preview (exit 0)",
  "wt: new: /Users/me/checkouts/cmux/lane--digest-notice-preview",
].join("\n");
const TESTS = [
  "[notice from acpmux] Background command finished: cmux-ci test -- bun test incomingMessage (exit 0)",
  "142 pass / 0 fail",
].join("\n");
const FAILED = [
  "[notice from acpmux · WARN] Background command failed: cmux-ci compile-check (exit 1)",
  "error TS2345 in IncomingMessageCard.tsx:422",
].join("\n");
const REVIEW = "[review-lane] **SHIP** at `64d6b1b`: the preview reads the first message.";

/// A turn of `[sender, text]` messages as acpmux writes it, read as direct.ts reads its record.
function digest(parts: readonly (readonly [string, string])[], minutes: number) {
  const text = [
    `${parts.length} messages from other agents arrived while you were busy. Each follows as it was sent, oldest first.`,
    ...parts.flatMap(([from, body], index) => ["", `[agent message ${index + 1} of ${parts.length}] from ${from}`, "", body]),
  ].join("\n");
  const provenance = { kind: "agent_digest", messages: parts.map(([from]) => ({ from })) };
  const incoming = incomingPrompt(text, { client: "acpmux", _meta: { provenance } });
  if (incoming?.kind !== "message") return user(text, minutes);
  const { notice, text: body } = incoming.message;
  return user(notice ? noticeRowText(notice, body) : body, minutes, { incoming, resend: text, untyped: true });
}

const RECEIVED_LINE = ".cv-received .cv-disclosure__toggle";

const openLine: Play = async (ctx) => {
  await ctx.click({ selector: RECEIVED_LINE });
  await ctx.waitFor(() => ctx.document.querySelector(`${RECEIVED_LINE}[aria-expanded="true"]`));
};

function snapshot(last: ReturnType<typeof user>) {
  return chat(
    [
      user("Start the digest preview lane and run its tests.", 9),
      assistant("Started the worktree and the tests in the background.", 8.5),
      summary(8.5, { status: "completed" }),
      last,
    ],
    {
      title: "coordinator",
      sessions: [session({ sessionId: SESSION_ID, title: "coordinator", name: "coordinator" })],
    },
  );
}

const NOTICES = [
  ["acpmux", FINISHED],
  ["acpmux", TESTS],
] as const;

export default agentPaneEntry({
  id: "agent-pane.digest-message",
  title: "Messages that waited for a busy chat, as one line",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/conversation/incomingMessage.ts"],
  variants: {
    notices: {
      note: 'Two acpmux notices in one turn: one notice row, the first title on the line, never "acpmux acpmux".',
      snapshot: snapshot(digest(NOTICES, 3)),
    },
    "notices-open": {
      note: "Opened: each notice's title in bold over its body.",
      snapshot: snapshot(digest(NOTICES, 3)),
      play: openLine,
    },
    "notices-warn": {
      note: "A warning among them: the row takes its mark and its title.",
      snapshot: snapshot(digest([...NOTICES, ["acpmux", FAILED]], 3)),
    },
    mixed: {
      note: "A notice then a lane's message: the line previews the first message's words.",
      snapshot: snapshot(
        digest(
          [
            ["acpmux", FINISHED],
            ["review-lane", REVIEW],
          ],
          3,
        ),
      ),
    },
    "mixed-open": {
      note: "Opened: each message under its sender, the notice's title over its body.",
      snapshot: snapshot(
        digest(
          [
            ["acpmux", FINISHED],
            ["review-lane", REVIEW],
          ],
          3,
        ),
      ),
      play: openLine,
    },
  },
});

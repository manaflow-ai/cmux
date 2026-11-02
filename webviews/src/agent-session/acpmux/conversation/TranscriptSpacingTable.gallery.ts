// l10n-allow-file: gallery fixtures (sample lanes, messages and commands), not shipped UI.
// Every row kind of Leo's 2026-11-02 transcript capture, in one coordinator chat, so one test can
// measure each pair's gap against the settled values (leo-workspace design/transcript-spacing.md;
// Leo, 2026-11-02: "ugh we'll really want to study how chatgpt desktop and claude desktop do their
// spacing i just feel gross looking at these" and "we need to like enforce the good versions when
// we find them later in the specs/comments/tests or something"). A finished two-paragraph reply and
// its footer; an inbox row; then a running turn: "Sent 3 messages", a one-line reply, "Ran 2
// commands", an inbox row, the live line "Sending message to …" and the waiting group "2 messages
// from 2 sessions". transcript-spacing-table.test.ts measures it against transcriptSpacing.ts.
import { agentPaneEntry } from "../../../gallery/format";
import { SESSION_ID, activity, assistant, chat, session, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity } from "../model";
import { incomingPrompt } from "./incomingMessage";
import { inboxText } from "./inboxNotice";

const send = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", {
    inputSummary: JSON.stringify({ to, message }),
    output: `delivered to ${to}\n`,
  });
const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });
const sending = (target: string, text: string): AcpmuxActivity =>
  tool(`acpmux send ${target} '${text}'`, "execute", "in_progress", {
    command: `acpmux send ${target} '${text}'`,
    description: `Ask ${target}`,
  });

const SESSIONS: Record<string, string> = { "grid-lane": "s-grid", "picker-lane": "s-picker", "review-box": "s-review" };

/// An inbox notice of one message from each of two sessions, as acpmux sends it (hub/inbox.rs
/// `render`; InboxNotice.gallery.ts draws the full range): its line reads "2 messages from 2 sessions".
function inbox(minutes: number, from: [string, string]) {
  const threads = from.map((name, index) => ({
    threadId: `pr:${2210 + index}-${minutes}`,
    label: `#${2210 + index}`,
    from: name,
    session: SESSIONS[name]!,
    text: index === 0 ? "Review passed at e34ce27." : "SHIP at 9c41a07.",
  }));
  const text = [
    "[inbox] New messages from other agents in 2 threads.",
    ...threads.map((t) => `- 1 new in ${t.label} from ${t.from}: ${t.text} (thread ${t.threadId})`),
  ].join("\n");
  const provenance = {
    kind: "inbox_notice",
    noticeId: `inbox-notice-spacing-${minutes}`,
    threads: threads.map((t, index) => ({
      threadId: t.threadId,
      label: t.label,
      new: 1,
      from: [t.from],
      fromSession: t.session,
      promptIds: [`p-spacing-${minutes}-${index}`],
      blocker: false,
      preview: t.text,
      messages: [{ from: t.from, text: t.text }],
    })),
  };
  const incoming = incomingPrompt(text, { client: "acpmux", _meta: { provenance } });
  return incoming?.kind === "inbox"
    ? user(inboxText(incoming.notice), minutes, { incoming, untyped: true })
    : user(text, minutes);
}

const REPLY = [
  "The three lanes have their briefs: grid-lane takes the row pitch, picker-lane the menu polish and review-box the exact-head review.",
  "I'll land each as its review passes and send you the links together once the nightly has picked them up.",
].join("\n\n");

/// Two messages from two sessions that wait for the turn to end (PendingMessagesCard.tsx): "2
/// messages from 2 sessions", as in Leo's capture.
const WAITING = [
  { id: "w1", from: "grid-lane", session: "s-grid", text: "Review passed at e34ce27; landing #2210 now." },
  { id: "w2", from: "review-box", session: "s-review", text: "Still SHIP at 9c41a07." },
].map((m) => ({
  id: m.id,
  prompt: m.text,
  message: { name: m.from, sessionId: m.session, harness: "claude", text: m.text, raw: m.text },
}));

export default agentPaneEntry({
  id: "agent-pane.transcript-spacing-table",
  title: "Transcript spacing: every row kind against the settled values",
  area: "Agent pane",
  height: 1000,
  covers: [
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/transcriptGrid.ts",
    "agent-session/acpmux/transcriptSpacing.ts",
  ],
  variants: {
    shipped: {
      note: 'A finished reply and its footer; an inbox row; then a running turn: "Sent 3 messages", a reply line, "Ran 2 commands", an inbox row, "Sending message to …" and "2 messages from 2 sessions".',
      snapshot: chat(
        [
          user("Where are the three polish lanes?", 14),
          assistant(REPLY, 13.5),
          summary(13.4, { status: "completed", durationMs: 34_000, toolCount: 0 }),
          inbox(9, ["grid-lane", "review-box"]),
          user("Hand the three polish lanes their briefs.", 6),
          activity(
            [
              send("grid-lane", "Take the one-line row pitch."),
              send("picker-lane", "Take the menu polish."),
              send("review-box", "Review #2214 at its head."),
            ],
            5.9,
          ),
          assistant("Briefs are out; checking #2210 before I land it.", 5.5),
          activity([run("Checked #2210", "gh pr checks 2210"), run("Read the head", "git log --oneline -1")], 5),
          inbox(3, ["picker-lane", "grid-lane"]),
          activity([sending("review-box", "Is #2214 still SHIP at its head?")], 1.8),
        ],
        {
          title: "polish-coordinator",
          isWorking: true,
          queue: WAITING,
          sessions: [
            session({ sessionId: SESSION_ID, title: "polish-coordinator", name: "polish-coordinator" }),
            session({ sessionId: "s-grid", title: "grid-lane", name: "grid-lane" }),
            session({ sessionId: "s-picker", title: "picker-lane", name: "picker-lane", harness: "codex" }),
            session({ sessionId: "s-review", title: "review-box", name: "review-box", harness: "codex" }),
          ],
        },
      ),
    },
  },
});

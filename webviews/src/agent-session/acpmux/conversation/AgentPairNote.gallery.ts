// l10n-allow-file: gallery fixtures (sample prompts and chat names), not shipped UI.
// A paused agent pair in the transcript (AgentPairNote.tsx): acpmux stopped two agent chats that
// kept messaging each other without progress, holds the other chat's messages, and offers Resume;
// once resumed, one quiet line.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";

const peer = "0190a000-0000-7000-8000-00000000beef";

export default agentPaneEntry({
  id: "agent-pane.agent-pair-note",
  title: "Agent pair notes",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/AgentPairNote.tsx"],
  variants: {
    paused: {
      note: "Two agents went back and forth ten times without progress; acpmux holds the reviewer's next two messages.",
      snapshot: chat([
        user("Ask the reviewer chat to sign off on the migration", 6),
        assistant("Sent the migration to the reviewer for sign-off.", 5),
        summary(5, { status: "completed", durationMs: 9_000, toolCount: 1 }),
        row("agentPair", 3, {
          agentPair: { peer, peerName: "Migration reviewer", reason: "alternating", count: 10, held: 2 },
        }),
      ]),
    },
    repeating: {
      note: "The other chat sent the same message again and again; nothing is held on this side.",
      snapshot: chat([
        user("Keep the release checklist in sync with the deploy chat", 4),
        row("agentPair", 2, {
          agentPair: { peer, peerName: "Deploy", reason: "repeating", count: 4, held: 0 },
        }),
      ]),
    },
    resumed: {
      note: "After Resume (or the person's next prompt), the note collapses to one line.",
      snapshot: chat([
        user("Ask the reviewer chat to sign off on the migration", 6),
        assistant("Sent the migration to the reviewer for sign-off.", 5),
        summary(5, { status: "completed", durationMs: 9_000, toolCount: 1 }),
        row("agentPair", 3, {
          agentPair: {
            peer,
            peerName: "Migration reviewer",
            reason: "alternating",
            count: 10,
            held: 2,
            resumed: true,
          },
        }),
      ]),
    },
  },
});

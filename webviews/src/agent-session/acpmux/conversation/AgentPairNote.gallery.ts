// l10n-allow-file: gallery fixtures (sample prompts and chat names), not shipped UI.
// A paused agent pair in the transcript (AgentPairNote.tsx): acpmux stopped two agent chats that
// kept messaging each other without progress (or past the cap, or after a held message failed to
// deliver), holds the other chat's messages, and offers Resume and a Show held messages list; once
// resumed, one quiet line with how many it delivered and, apart, how many it dropped.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxAgentPair } from "../model";

const peer = "0190a000-0000-7000-8000-00000000beef";
const held = [
  { promptId: "p-1", text: "Following up: can you confirm the migration is safe to run on the replica first?" },
  { promptId: "p-2", text: "Checking in again on the replica question before I sign off." },
];
const pair = (fields: Partial<AcpmuxAgentPair> = {}): AcpmuxAgentPair => ({
  peer,
  peerName: "Migration reviewer",
  reason: "alternating",
  count: 10,
  held,
  released: 0,
  dropped: 0,
  ...fields,
});
const before = [
  user("Ask the reviewer chat to sign off on the migration", 6),
  assistant("Sent the migration to the reviewer for sign-off.", 5),
  summary(5, { status: "completed", durationMs: 9_000, toolCount: 1 }),
];

export default agentPaneEntry({
  id: "agent-pane.agent-pair-note",
  title: "Agent pair notes",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/AgentPairNote.tsx"],
  variants: {
    paused: {
      note: "Two agents went back and forth ten times without progress; acpmux holds the reviewer's next two messages.",
      snapshot: chat([...before, row("agentPair", 3, { agentPair: pair() })]),
    },
    "held-list": {
      note: "Show held messages opened: each held message's preview, in the order acpmux held it.",
      snapshot: chat([...before, row("agentPair", 3, { agentPair: pair() })]),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-agent-pair__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-agent-pair__held"));
      },
    },
    repeating: {
      note: "The other chat sent the same message again and again; nothing is held on this side.",
      snapshot: chat([
        user("Keep the release checklist in sync with the deploy chat", 4),
        row("agentPair", 2, { agentPair: pair({ peerName: "Deploy", reason: "repeating", count: 4, held: [] }) }),
      ]),
    },
    cap: {
      note: "The pair passed acpmux's cap (more than 20 messages within 10 minutes with no message from the person); the window is spelled out in the pane language.",
      snapshot: chat([
        ...before,
        row("agentPair", 3, { agentPair: pair({ reason: "cap", count: 21, windowSecs: 600 }) }),
      ]),
    },
    "release-failed": {
      note: "After Resume, a held message failed to deliver: acpmux paused the pair again with the rest still held.",
      snapshot: chat([
        ...before,
        row("agentPair", 3, { agentPair: pair({ held: [], released: 1, resumed: true }) }),
        row("agentPair", 2, {
          agentPair: pair({ reason: "release_failed", count: 0, error: "the turn failed", held: held.slice(1) }),
        }),
      ]),
    },
    resumed: {
      note: "After Resume (or the person's next prompt), the note collapses to one line that counts what acpmux delivered, and what it dropped.",
      snapshot: chat([
        ...before,
        row("agentPair", 3, { agentPair: pair({ held: [], released: 2, dropped: 1, resumed: true }) }),
      ]),
    },
  },
});

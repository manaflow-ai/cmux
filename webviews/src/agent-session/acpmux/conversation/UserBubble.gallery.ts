// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A prompt's bubble (UserBubble.tsx): Copy and Edit under it on hover. Edit shows on a Claude chat's
// prompts after its first turn, which acpmux can fork through (cx-ncc.60).
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../model";

const claude = (snapshot: AcpmuxSnapshot): AcpmuxSnapshot => ({
  ...snapshot,
  summary: snapshot.summary && { ...snapshot.summary, family: "claude" },
});

const turns = (family: (snapshot: AcpmuxSnapshot) => AcpmuxSnapshot) =>
  family(
    chat([
      user("Add retry with backoff to the uploader", 9, { seq: 1 }),
      assistant("Done: three tries, doubling from 200 ms, only on 5xx and timeouts.", 8.5),
      summary(8.5, { seq: 3, status: "completed" }),
      user("Now cover it with a test that fakes two timeouts", 6, { seq: 4 }),
      assistant("Added `uploader.retry.test.ts`; it passes and fails without the retry.", 5),
      summary(5, { seq: 6, status: "completed" }),
    ]),
  );

export default agentPaneEntry({
  id: "agent-pane.user-bubble",
  title: "Prompt bubble",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/UserBubble.tsx"],
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }],
  variants: {
    claude: {
      note: "A Claude chat: hover a later prompt for Copy and Edit; the first prompt has Copy only.",
      snapshot: turns(claude),
    },
    other: {
      note: "Another agent forks only at a chat's end: prompts offer Copy only.",
      snapshot: turns((snapshot) => snapshot),
    },
  },
});

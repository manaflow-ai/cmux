// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent question card on the shared CmuxAgentQuestion fixtures (the same asks the Swift card,
// acpmux and agent-question-card.test.ts use), so the gallery advisory run captures every state on
// Linux Chromium without a Mac, a tagged build or a logged-in agent.
import pending4 from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-4-questions.json";
import pendingMulti from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-multi.json";
import pendingOther from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-other-typing.json";
import pendingSingle from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-single.json";
import pendingPreview from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-with-preview.json";
import { componentEntry } from "../../../gallery/format";
import type { AgentQuestion, QuestionReply } from "./model";
import { QuestionCard } from "./QuestionCard";

type Props = { question: AgentQuestion; onReply(reply: QuestionReply): void };

/// The card sits where the agent pane puts it: inside .acpmux-shell (which defines the card tokens,
/// the amber input color among them) and the bottom ask stack.
function QuestionCardInPane(props: Props) {
  return (
    <div className="acpmux-shell" style={{ flexDirection: "column", justifyContent: "flex-end", paddingTop: 16 }}>
      <div className="acpmux-permission">
        <div className="acpmux-asks-stack">
          <QuestionCard {...props} />
        </div>
      </div>
    </div>
  );
}

const variant = (question: unknown, note: string) => ({
  note,
  props: { question: question as AgentQuestion, onReply: () => undefined },
});

export default componentEntry({
  id: "agent-pane.question-card",
  title: "Agent question card",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-question" }],
  covers: ["agent-session/acpmux/question/QuestionCard.tsx#QuestionCard"],
  styles: () => import("../styles.css"),
  load: async () => QuestionCardInPane,
  variants: {
    "pending-single": variant(
      pendingSingle,
      "A Claude Code AskUserQuestion: the Needs your input pill, the question as the header, radio rows, Skip and Submit.",
    ),
    "pending-multi": variant(pendingMulti, "A multi-select ask: checkbox rows."),
    "pending-other-typing": variant(pendingOther, "Other turned into an inline text field."),
    "pending-with-preview": variant(pendingPreview, "Options with a preview beside the highlighted row."),
    "pending-4-questions": variant(pending4, "Four questions in one ask."),
  },
});

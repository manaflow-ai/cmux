// l10n-allow-file: gallery fixtures, not shipped UI.
// An agent question whose option previews are HTML (Claude Code's AskUserQuestion with
// previewFormat "html"), in the three looks HtmlPreview.tsx offers, beside the monospace preview
// it sits next to. The fixture is the shared CmuxAgentQuestion one, so the Swift tests, the web
// mapping test and this entry read the same ask.
import pendingHtml from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-with-html-preview.json";
import pendingPreview from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-with-preview.json";
import { componentEntry } from "../../../gallery/format";
import { HtmlPreviewLookContext, type HtmlPreviewLook } from "./HtmlPreview";
import type { AgentQuestion } from "./model";
import { QuestionCard } from "./QuestionCard";

type Props = { question: AgentQuestion; look: HtmlPreviewLook };

/// The card where the agent pane puts it: inside .acpmux-shell and the bottom ask stack.
function HtmlPreviewInPane({ question, look }: Props) {
  return (
    <HtmlPreviewLookContext.Provider value={look}>
      <div className="acpmux-shell" style={{ flexDirection: "column", justifyContent: "flex-end", paddingTop: 16 }}>
        <div className="acpmux-permission">
          <div className="acpmux-asks-stack">
            <QuestionCard question={question} onReply={() => undefined} />
          </div>
        </div>
      </div>
    </HtmlPreviewLookContext.Provider>
  );
}

const html = pendingHtml as unknown as AgentQuestion;
const variant = (look: HtmlPreviewLook, note: string, question: AgentQuestion = html) => ({
  note,
  props: { question, look },
});

export default componentEntry({
  id: "agent-pane.question-card-html-preview",
  title: "Agent question card: HTML previews",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-question" }],
  covers: ["agent-session/acpmux/question/HtmlPreview.tsx#HtmlPreview"],
  styles: () => import("../styles.css"),
  load: async () => HtmlPreviewInPane,
  variants: {
    framed: variant(
      "framed",
      "The default: the highlighted option's HTML mockup in the card's preview box, like a monospace preview.",
    ),
    "framed-next-option": {
      ...variant("framed", "Arrow down: the preview follows the highlight to Compact row."),
      // The card takes the idle keyboard on arrival, so the arrow moves its highlight.
      play: (ctx) => ctx.press("ArrowDown"),
    },
    canvas: variant("canvas", "The mockup on an inset artboard in the page colour, with an edge."),
    bleed: variant("bleed", "No box: the mockup fills the preview column."),
    monospace: variant(
      "framed",
      "Unchanged: a markdown-mode preview in its monospace box.",
      pendingPreview as unknown as AgentQuestion,
    ),
  },
});

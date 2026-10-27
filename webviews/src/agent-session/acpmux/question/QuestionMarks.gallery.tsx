// l10n-allow-file: gallery fixtures, not shipped UI.
// An agent question whose prompt, option labels and descriptions carry inline Markdown (`code`,
// **bold**, *italic*, ~~struck~~, a link): drawn as marks (inlineText.tsx), never as backticks and
// asterisks. Three looks of inline code: tint (shipped), mono (no tint) and ring (a hairline).
import { componentEntry } from "../../../gallery/format";
import type { AgentQuestion } from "./model";
import { QuestionCard } from "./QuestionCard";

type Look = "tint" | "mono" | "ring";
type Props = { question: AgentQuestion; look: Look };

function QuestionMarksInPane({ question, look }: Props) {
  return (
    <div
      className="acpmux-shell acpmux-question-marks-gallery"
      data-code-look={look}
      style={{ flexDirection: "column", justifyContent: "flex-end", paddingTop: 16 }}
    >
      <div className="acpmux-permission">
        <div className="acpmux-asks-stack">
          <QuestionCard question={question} onReply={() => undefined} />
        </div>
      </div>
    </div>
  );
}

const source = {
  harness: "claude" as const,
  session: "sess_marks_1",
  permission: "perm_toolu_marks",
  agentName: "Claude Code",
  answerOption: "allow_once",
  rejectOption: "reject_once",
};

/// A single choice with marks in the prompt, the labels and the descriptions.
const single: AgentQuestion = {
  id: "perm_toolu_marks",
  source,
  items: [
    {
      id: "q0",
      header: "Date library",
      prompt: "Which library should `formatDate` use?",
      options: [
        {
          id: "date-fns (Recommended)",
          label: "date-fns (Recommended)",
          detail: "Tree-shakes to **~4 KB**; already a dependency of `web/`.",
        },
        {
          id: "Temporal",
          label: "`Temporal`",
          detail: "The *standard* API; needs a polyfill on ~~Safari 17~~ every Safari today.",
        },
        {
          id: "Intl only",
          label: "Intl only",
          detail: "No dependency. See [the MDN page](https://developer.mozilla.org/) for `Intl.DateTimeFormat`.",
        },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: { kind: "pending" },
};

/// A multi-select with marks.
const multi: AgentQuestion = {
  id: "perm_toolu_marks_multi",
  source: { ...source, permission: "perm_toolu_marks_multi" },
  items: [
    {
      id: "q0",
      header: "Checks",
      prompt: "Which checks should run **before** each push?",
      options: [
        { id: "lint", label: "Lint", detail: "`bun run check` in `webviews/`." },
        { id: "types", label: "Types", detail: "`tsc --noEmit`, about *20 s*." },
        { id: "tests", label: "Unit tests", detail: "Only the suites the change touches." },
      ],
      multiSelect: true,
      allowsOther: true,
    },
  ],
  state: { kind: "pending" },
};

const variant = (question: AgentQuestion, look: Look, note: string) => ({ note, props: { question, look } });

export default componentEntry({
  id: "agent-pane.question-card-marks",
  title: "Agent question card: inline Markdown",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-question" }],
  covers: ["agent-session/acpmux/question/QuestionCard.tsx#QuestionCard"],
  styles: () => Promise.all([import("../styles.css"), import("./QuestionMarks.gallery.css")]),
  load: async () => QuestionMarksInPane,
  variants: {
    "single-tint": variant(
      single,
      "tint",
      "Shipped: inline code on a faint tint, as in the transcript; bold, italic and struck text as marks; a link as its label.",
    ),
    "single-mono": variant(single, "mono", "Alternative: inline code in the mono face only, no tint."),
    "single-ring": variant(single, "ring", "Alternative: inline code in a hairline ring."),
    "multi-tint": variant(multi, "tint", "Shipped, multi-select: checkbox rows with marks."),
    "multi-mono": variant(multi, "mono", "Alternative, multi-select: mono only."),
    "multi-ring": variant(multi, "ring", "Alternative, multi-select: hairline ring."),
  },
});

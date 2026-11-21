// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent's own wrap-up call (wrapUp.ts, acpmux's `wrap_up` tool) as the next-step box at the end
// of a turn: a recap of what changed and where things stand, and, when the turn leaves a decision,
// one question with one or two answers (reference claude/web/october-recap-card). Three looks:
// box (shipped: the recap muted at the top of the box, then the question and the answers, as
// Claude desktop), divider (the same box with a hairline between the recap and the question) and
// split (the recap as plain muted prose above a box that holds only the question). Each with two
// answers, a yes-or-no question, a recap alone and answered.
import { componentEntry } from "../../../gallery/format";
import { chosenAnswer } from "./nextStepAsk";
import { NextStepCard } from "./NextStepCard";
import { wrapUpAsk } from "./wrapUp";

type Look = "box" | "divider" | "split";
type Props = { look: Look; input: Record<string, unknown>; reply?: string };

const PROSE = "Done. The grid reserves its space now.";
const RECAP =
  "Product images now have a width and height, and the grid reserves a 4:5 box while they load, so the product grid no longer shifts. All 14 tests pass, including the new layout shift test.";
const CHOICES = { recap: RECAP, ask: "Should I open a PR for this?", actions: ["Yes, open PR", "Not now"] };
const YES_NO = { recap: RECAP, ask: "Should I also fix the same shift on the cart page?" };
const ALONE = { recap: RECAP };

function WrapUpInPane({ look, input, reply }: Props) {
  const ask = wrapUpAsk({
    title: "mcp__acpmux__wrap_up",
    status: "completed",
    inputSummary: JSON.stringify(input),
  } as Parameters<typeof wrapUpAsk>[0])!;
  const shown = look === "split" && ask.question ? { ...ask, recap: undefined } : ask;
  return (
    <div
      className="acpmux-shell acpmux-next-step-gallery"
      data-next-step-look={look}
      style={{ flexDirection: "column", justifyContent: "flex-end", gap: 12, padding: 16 }}
    >
      <p style={{ margin: 0, color: "var(--agent-text)" }}>{PROSE}</p>
      {look === "split" && ask.question && ask.recap && (
        <p style={{ margin: 0, color: "var(--agent-muted)" }}>{ask.recap}</p>
      )}
      <NextStepCard
        ask={shown}
        answer={reply === undefined ? undefined : chosenAnswer(ask, reply)}
        onAnswer={() => Promise.resolve()}
        registerKey={() => () => undefined}
      />
    </div>
  );
}

const variant = (look: Look, input: Record<string, unknown>, reply: string | undefined, note: string) => ({
  note,
  props: { look, input, reply },
});

export default componentEntry({
  id: "agent-pane.next-step-wrap-up",
  title: "Agent pane: the agent's wrap-up box at the end of a turn",
  area: "Agent pane",
  pane: true,
  height: 320,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-next-step" }],
  covers: ["agent-session/acpmux/conversation/NextStepCard.tsx#NextStepCard"],
  styles: () => Promise.all([import("../styles.css"), import("./NextStepCard.gallery.css")]),
  load: async () => WrapUpInPane,
  variants: {
    "box-choices": variant("box", CHOICES, undefined, "Shipped: the recap muted on top, the question, two answers."),
    "box-yes-no": variant("box", YES_NO, undefined, "Shipped: a question with no answers gets Yes and Not now."),
    "box-recap-only": variant("box", ALONE, undefined, "Shipped: nothing to decide, the recap alone."),
    "box-answered": variant("box", CHOICES, "Yes, open PR", "Shipped: answered, the recap stays above the answer."),
    "divider-choices": variant("divider", CHOICES, undefined, "Alternative: a hairline between recap and question."),
    "divider-recap-only": variant("divider", ALONE, undefined, "Alternative: recap alone."),
    "split-choices": variant("split", CHOICES, undefined, "Alternative: the recap as prose, the box only asks."),
    "split-recap-only": variant("split", ALONE, undefined, "Alternative: recap alone."),
  },
});

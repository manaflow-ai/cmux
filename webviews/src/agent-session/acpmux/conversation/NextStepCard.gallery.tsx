// l10n-allow-file: gallery fixtures, not shipped UI.
// A tagged ask at the end of a turn (nextStepAsk.ts) as a card with its answers as buttons. Five
// looks: box (shipped, Claude desktop's next-step box: a bordered card, the first answer filled in
// the text colour with ⌘↩, as the question card's Submit), recap (the recap card's accent yes and
// bare text answers, RecapCard.tsx), inline (no card: the question and the buttons under the
// prose), consent (the consent card's buttons at the end of the row, ChatGPT's) and list (the
// answers stacked as rows, the question card's). Each look in its pending and answered states, with Yes and No, and with a list of answers.
import { componentEntry } from "../../../gallery/format";
import { nextStepAsk, chosenAnswer } from "./nextStepAsk";
import { NextStepCard } from "./NextStepCard";

type Look = "box" | "recap" | "inline" | "consent" | "list";
type Props = { look: Look; text: string; reply?: string };

const PROSE =
  "The slow session wasn't foregrounded by acpmux or cmux NEXT. It ran about 40 slow Bash calls in the foreground itself, and they stalled the turn.";

const YES_NO = `${PROSE}\n\n[outward] Should I add a hook that pushes known-slow commands to the background? It applies to every lane.`;
const CHOICES = `${PROSE}\n\n[taste] Which fix first?\n- Add the hook\n- Not now\n- Fix CI`;

function NextStepInPane({ look, text, reply }: Props) {
  const ask = nextStepAsk(text)!;
  return (
    <div
      className="acpmux-shell acpmux-next-step-gallery"
      data-next-step-look={look}
      style={{ flexDirection: "column", justifyContent: "flex-end", gap: 12, padding: 16 }}
    >
      <p style={{ margin: 0, color: "var(--agent-text)" }}>{ask.rest}</p>
      <NextStepCard
        ask={ask}
        answer={reply === undefined ? undefined : chosenAnswer(ask, reply)}
        onAnswer={() => Promise.resolve()}
        registerKey={() => () => undefined}
      />
    </div>
  );
}

const variant = (look: Look, text: string, reply: string | undefined, note: string) => ({
  note,
  props: { look, text, reply },
});

export default componentEntry({
  id: "agent-pane.next-step-card",
  title: "Agent pane: tagged ask as answer buttons",
  area: "Agent pane",
  pane: true,
  height: 280,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-next-step" }],
  covers: ["agent-session/acpmux/conversation/NextStepCard.tsx#NextStepCard"],
  styles: () => Promise.all([import("../styles.css"), import("./NextStepCard.gallery.css")]),
  load: async () => NextStepInPane,
  variants: {
    "box-choices": variant(
      "box",
      CHOICES,
      undefined,
      "Shipped: Claude desktop's box, three answers, the first filled with ⌘↩.",
    ),
    "box-yes-no": variant(
      "box",
      YES_NO,
      undefined,
      "Shipped: a yes-or-no ask gets Yes and No; its tail is the muted line.",
    ),
    "box-answered": variant("box", CHOICES, "Add the hook", "Shipped: answered, the question and the answer in grey."),
    "box-answered-typed": variant(
      "box",
      YES_NO,
      "Only for lanes, not coordinators",
      "Shipped: a typed reply reads as the answer.",
    ),
    "recap-choices": variant(
      "recap",
      CHOICES,
      undefined,
      "Alternative: the recap card's accent yes, the rest bare text.",
    ),
    "inline-choices": variant("inline", CHOICES, undefined, "Alternative: no card, buttons under the prose."),
    "inline-answered": variant("inline", CHOICES, "Add the hook", "Alternative: answered."),
    "consent-choices": variant("consent", CHOICES, undefined, "Alternative: the consent card, buttons right-aligned."),
    "consent-yes-no": variant("consent", YES_NO, undefined, "Alternative: the consent card, yes or no."),
    "list-choices": variant("list", CHOICES, undefined, "Alternative: answers stacked as rows, the question card's."),
  },
});

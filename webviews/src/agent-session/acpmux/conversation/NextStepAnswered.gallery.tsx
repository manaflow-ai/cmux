// l10n-allow-file: gallery fixtures, not shipped UI.
// A wrap-up ask the person just clicked an answer on, before the transcript reads their reply (Leo,
// 2026-11-19, on his coordinator's "Needs your input" card: "plus it's not instant yet"). The click
// sends at once; the card shows the answer in place in the same frame. Three looks for that moment:
// pressed (shipped: the same box and answers row, the picked answer filled with a check, the rest
// quiet, so nothing moves), line (one checked line in the answers' place) and folded (the answered
// card the transcript's reply folds it to, at once). Each pinned above the composer, as Leo saw it.
import { componentEntry } from "../../../gallery/format";
import { NextStepCard } from "./NextStepCard";
import { setAnswerState } from "./waitingAskStore";
import { wrapUpAsk } from "./wrapUp";

type Look = "pressed" | "line" | "folded";
type Props = { look: Look; picked?: string };

const ASK = {
  recap: "The pool's clippy and React Doctor runs are green on every lane PR this week.",
  ask: "[trust] Let our pool's results count for the required clippy and React Doctor checks?",
  actions: ["Yes, count them", "Not now"],
};

function AnsweredInPane({ look, picked }: Props) {
  const ask = wrapUpAsk({
    title: "mcp__acpmux__wrap_up",
    status: "completed",
    inputSummary: JSON.stringify(ASK),
  } as Parameters<typeof wrapUpAsk>[0])!;
  const { recap: _recap, ...question } = ask;
  const key = `gallery-answered-${look}-${picked ?? "none"}`;
  if (picked) setAnswerState(key, { sent: picked });
  return (
    <div
      className="acpmux-shell"
      data-answered-look={look}
      style={{ flexDirection: "column", justifyContent: "flex-end", gap: 12, padding: 16 }}
    >
      <div className="acpmux-permission acpmux-asks-stack" style={{ padding: 0 }}>
        <section className="acpmux-pending-ask">
          <div className="acpmux-pending-ask__head">
            <span className="acpmux-pending-ask__label">Needs your input</span>
          </div>
          <NextStepCard
            className="ui-glass ui-glass-floats acpmux-stack-material"
            ask={question}
            onAnswer={() => new Promise(() => undefined)}
            registerKey={() => () => undefined}
            answerKey={key}
            asker="Claude Code"
            answeredLook={look}
          />
        </section>
      </div>
    </div>
  );
}

const variant = (look: Look, picked: string | undefined, note: string) => ({ note, props: { look, picked } });

export default componentEntry({
  id: "agent-pane.next-step-answered",
  title: "Agent pane: a wrap-up ask the moment its answer is clicked",
  area: "Agent pane",
  pane: true,
  height: 280,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-next-step" }],
  covers: ["agent-session/acpmux/conversation/NextStepCard.tsx#NextStepCard"],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../bottomStack.css"),
      import("./PendingAsks.css"),
      import("./NextStepCard.css"),
    ]),
  load: async () => AnsweredInPane,
  variants: {
    waiting: variant("pressed", undefined, "Before the click: the question and its answers, the first with ⌘↩."),
    pressed: variant(
      "pressed",
      "Yes, count them",
      "Shipped: same box, the picked answer filled and checked, the rest quiet.",
    ),
    "pressed-other": variant("pressed", "Not now", "Shipped: the second answer picked."),
    line: variant("line", "Yes, count them", "Alternative: one checked line in the answers' place."),
    folded: variant("folded", "Yes, count them", "Alternative: folds at once to the answered card."),
  },
});

// l10n-allow-file: gallery fixtures, not shipped UI.
// How an ask that ended without an answer reads, by how it ended (record.ts `cancelReason`): Skipped,
// Stopped before an answer, or Not answered when the record can't tell. Three looks: card (shipped,
// the answered card's shape with the outcome in grey under the question), pill (a borderless fill)
// and rule (no card, a hairline at its start).
import cancelled from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/cancelled.json";
import { componentEntry } from "../../../gallery/format";
import type { AgentQuestion, CancelReason } from "./model";
import { QuestionCard } from "./QuestionCard";

type Look = "card" | "pill" | "rule";
type Props = { reason?: CancelReason; look: Look };

function EndedInPane({ reason, look }: Props) {
  const ask = cancelled as unknown as AgentQuestion;
  const ended = (why?: CancelReason): AgentQuestion => ({
    ...ask,
    state: why ? { kind: "cancelled", reason: why } : { kind: "cancelled" },
  });
  return (
    <div
      className="acpmux-shell acpmux-question-ended-gallery"
      data-ended-look={look}
      style={{ flexDirection: "column", justifyContent: "flex-end", gap: 8, paddingTop: 16 }}
    >
      <QuestionCard question={ended(reason)} onReply={() => undefined} />
    </div>
  );
}

const variant = (reason: CancelReason | undefined, look: Look, note: string) => ({ note, props: { reason, look } });

export default componentEntry({
  id: "agent-pane.question-card-ended",
  title: "Agent question card: ended unanswered",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-question-cancelled" }],
  covers: ["agent-session/acpmux/question/QuestionCard.tsx#QuestionCard"],
  styles: () => Promise.all([import("../styles.css"), import("./QuestionEnded.gallery.css")]),
  load: async () => EndedInPane,
  variants: {
    "skipped-card": variant("skipped", "card", "Shipped: Skip pressed; Skipped in grey under the question."),
    "stopped-card": variant("stopped", "card", "Shipped: the turn stopped before an answer; the card says so."),
    "unknown-card": variant(undefined, "card", "Shipped: the record can't tell (no reject option); Not answered."),
    "skipped-pill": variant("skipped", "pill", "Alternative: a borderless fill."),
    "stopped-pill": variant("stopped", "pill", "Alternative: a borderless fill."),
    "skipped-rule": variant("skipped", "rule", "Alternative: a hairline rule at its start."),
    "stopped-rule": variant("stopped", "rule", "Alternative: a hairline rule at its start."),
  },
});

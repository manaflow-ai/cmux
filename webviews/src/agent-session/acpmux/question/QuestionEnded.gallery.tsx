// l10n-allow-file: gallery fixtures, not shipped UI.
// How an ask that ended without an answer reads, by how it ended (record.ts `cancelReason`): Skipped,
// Stopped before an answer, or Not answered when the record can't tell. Three looks of the line:
// line (shipped, the muted line #24325 drew), pill (the answered row's pill) and rule (a hairline).
import cancelled from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/cancelled.json";
import { componentEntry } from "../../../gallery/format";
import type { AgentQuestion, CancelReason } from "./model";
import { QuestionCard } from "./QuestionCard";

type Look = "line" | "pill" | "rule";
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
    "skipped-line": variant("skipped", "line", "Shipped: Skip pressed; the muted line says Skipped."),
    "stopped-line": variant("stopped", "line", "Shipped: the turn stopped before an answer; the line says so."),
    "unknown-line": variant(undefined, "line", "Shipped: the record can't tell (no reject option); Not answered."),
    "skipped-pill": variant("skipped", "pill", "Alternative: in the answered row's pill."),
    "stopped-pill": variant("stopped", "pill", "Alternative: in the answered row's pill."),
    "skipped-rule": variant("skipped", "rule", "Alternative: a hairline rule at its start."),
    "stopped-rule": variant("stopped", "rule", "Alternative: a hairline rule at its start."),
  },
});

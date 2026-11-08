// l10n-allow-file: gallery fixtures (a sample plan and its options), not shipped UI.
//
// A plan approval as it waits in the bottom stack (PermissionAsk.tsx PlanAsk): the "Needs your input"
// pill over the card, whose attention dot grows in as the agent asks and shrinks out as the person
// answers, with the card. Answering here (any answer) plays the exit; Ask again plays the entrance.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxPermission } from "../model";
import { PermissionCard } from "../PermissionCard";
import { PlanAsk } from "./PermissionAsk";

/// The attention dot (Leo 2026-11-08: "I mostly just meant the yellow circle thing"): "standard"
/// (shipped, 8px with its soft ring, beside the words in the pill), "small" (6px, no ring), "large"
/// (10px), "soft" (a paler tone, no ring) or "alone" (the dot with no words; the pill keeps its label
/// for assistive tech).
type Look = "standard" | "small" | "large" | "soft" | "alone";
/// How the card comes and goes around the dot: "grow" (shipped, its height and fade together, the
/// transcript moving with it) or "fade" (opacity only: its room opens at once and closes at the end).
type Motion = "grow" | "fade";
type Props = { look?: Look; motion?: Motion };

const dot = (look: Look) => `[data-look="${look}"] .acpmux-plan-ask-status .acpmux-needs-you-dot`;
const looks: Record<Exclude<Look, "standard">, string> = {
  small: `${dot("small")} { width: 6px; height: 6px; box-shadow: none; }`,
  large: `${dot("large")} { width: 10px; height: 10px; }`,
  soft: `${dot("soft")} { background: color-mix(in srgb, var(--acpmux-needs-you-mark) 55%, transparent); box-shadow: none; }`,
  alone: `[data-look="alone"] .acpmux-plan-ask-status .acpmux-question-status-pill { font-size: 0; gap: 0;
      padding: 0 var(--ds-space-2); }`,
};

const motions: Record<Exclude<Motion, "grow">, string> = {
  fade: `[data-motion="fade"] .acpmux-asks-stack > .acpmux-plan-ask { transition-property: opacity; }
    [data-motion="fade"] .acpmux-asks-stack > .acpmux-plan-ask:is([data-presence="from"], [data-presence="leaving"]) {
      grid-template-rows: 1fr; margin-top: 0; }`,
};

const plan: AcpmuxPermission = {
  permissionId: "gallery-plan-ask",
  kind: "other",
  title: "Approve plan",
  plan: "## Retry dropped uploads\n\n1. Retry a failed chunk twice in `uploadChunk`.\n2. Add a test for a dropped chunk.",
  pending: true,
  options: [
    { id: "allow_once", name: "Answer", kind: "allow_once", allow: true },
    { id: "acceptEdits", name: "Approve and auto-accept edits", kind: "allow_once", allow: true },
    { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
  ],
};

function GalleryPlanAsk({ look = "standard", motion = "grow" }: Props) {
  const [asking, setAsking] = useState(true);
  return (
    <div className="acpmux-shell" data-look={look} data-motion={motion} style={{ flexDirection: "column" }}>
      {look !== "standard" && <style>{looks[look]}</style>}
      {motion !== "grow" && <style>{motions[motion]}</style>}
      <div
        style={{ flex: 1, minHeight: 0, padding: "var(--ds-space-3) var(--ds-space-4)", color: "var(--agent-muted)" }}
      >
        <p style={{ margin: 0 }}>The transcript above the stack moves with the card.</p>
        {!asking && (
          <button type="button" className="acpmux-question-status" onClick={() => setAsking(true)}>
            <span className="acpmux-question-status-pill">Ask again</span>
          </button>
        )}
      </div>
      <div className="acpmux-permission acpmux-asks-stack">
        <PlanAsk permission={asking ? plan : undefined}>
          {(permission, leaving) => (
            <PermissionCard
              permission={permission}
              harness="claude"
              shortcuts={!leaving}
              onAnswer={() => setAsking(false)}
            />
          )}
        </PlanAsk>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.plan-ask",
  title: "Plan approval: needs your input",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/rows/PermissionAsk.tsx#PlanAsk"],
  load: async () => GalleryPlanAsk,
  styles: () =>
    Promise.all([
      import("../../../ui/glass/glass.css"),
      import("../styles.css"),
      import("../bottomStack.css"),
      import("../needsYou/needsYou.css"),
      import("../conversation/conversation.css"),
      import("../keys.css"),
    ]),
  widths: { narrow: 360, normal: 540, wide: 760 },
  height: 420,
  variants: {
    "dot-standard": {
      note: 'Chosen. Leo 2026-11-08: "I mostly just meant the yellow circle thing. I thought that was cute." The attention dot (8px, its soft ring) beside Needs your input grows in as the agent asks and shrinks out once answered: one scale and fade each way on the house settle (cubic-bezier(0.16, 1, 0.3, 1), 265 ms), never a loop or a pulse. The plan card grows and shrinks with it, height and fade together with the stack\'s gap, so the transcript moves in the same motion and nothing jumps when it ends. Answer to see the exit, Ask again for the entrance.',
      props: {},
    },
    "dot-small": {
      note: "Size B: 6px with no ring. Tidier, but at this size its grow is too small to notice.",
      props: { look: "small" },
    },
    "dot-large": {
      note: "Size C: 10px. The grow reads clearly, but the dot outweighs the words beside it.",
      props: { look: "large" },
    },
    "dot-soft": {
      note: "Tone B: a paler dot with no ring. Calmer, but it stops matching the sidebar's and tab strip's needs-input mark.",
      props: { look: "soft" },
    },
    "dot-alone": {
      note: "Without the label: the dot alone in its pill. Smallest, but the plan card then has no words for why it waits.",
      props: { look: "alone" },
    },
    "card-fade": {
      note: "Card motion B: the dot grows and shrinks, but the card only fades. Its room opens in one frame and closes in one frame after the fade, so the transcript jumps twice.",
      props: { motion: "fade" },
    },
  },
});

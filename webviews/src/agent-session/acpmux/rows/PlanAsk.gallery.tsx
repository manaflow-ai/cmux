// A plan approval as it waits in the bottom stack (PermissionAsk.tsx PlanAsk): the still "Needs your
// input" pill over the card, and the grow-in and shrink-out it plays as the agent asks and the person
// answers. Answering here (any answer) plays the exit; Ask again plays the entrance.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxPermission } from "../model";
import { PermissionCard } from "../PermissionCard";
import { PlanAsk } from "./PermissionAsk";

/// How the waiting state is marked: "pill" (shipped, the question card's tonal pill with its dot),
/// "dot" (the dot and the words, no fill) or "label" (the words alone, in the attention colour).
type Look = "pill" | "dot" | "label";
/// How the ask comes and goes: "grow" (shipped, its height and fade together, the transcript moving
/// with it), "rise" (the same, travelling up 8px from the composer as it grows) or "fade" (opacity only:
/// its room opens at once and closes when the fade ends).
type Motion = "grow" | "rise" | "fade";
type Props = { look?: Look; motion?: Motion };

const looks: Record<Exclude<Look, "pill">, string> = {
  dot: `[data-look="dot"] .acpmux-plan-ask-status .acpmux-question-status-pill { background: none; padding-left: 0; }`,
  label: `[data-look="label"] .acpmux-plan-ask-status .acpmux-needs-you-dot { display: none; }
    [data-look="label"] .acpmux-plan-ask-status .acpmux-question-status-pill { background: none; padding-left: 0;
      color: var(--acpmux-needs-you-mark); }`,
};

const motions: Record<Exclude<Motion, "grow">, string> = {
  rise: `[data-motion="rise"] .acpmux-asks-stack > .acpmux-plan-ask { transition-property: grid-template-rows, opacity,
      margin-top, translate; }
    [data-motion="rise"] .acpmux-asks-stack > .acpmux-plan-ask:is([data-presence="from"], [data-presence="leaving"]) {
      translate: 0 8px; }`,
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

function GalleryPlanAsk({ look = "pill", motion = "grow" }: Props) {
  const [asking, setAsking] = useState(true);
  return (
    <div className="acpmux-shell" data-look={look} data-motion={motion} style={{ flexDirection: "column" }}>
      {look !== "pill" && <style>{looks[look]}</style>}
      {motion !== "grow" && <style>{motions[motion]}</style>}
      <div style={{ flex: 1, minHeight: 0, padding: "12px 18px", color: "var(--agent-muted)" }}>
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
    "pill-grow": {
      note: 'Chosen. Leo 2026-11-08, on a recording of a needs-input card: "the animation shrinking out but ofc there\'s the growing in part when it starts". The question card\'s own still pill (the attention dot, no pulse) sits over the plan card; the two grow in together as the agent asks and shrink out together once answered: height and fade on the house settle (cubic-bezier(0.16, 1, 0.3, 1), 265 ms), the stack\'s gap closing with them, so the transcript moves in the same motion and nothing jumps when it ends. Answer to see the exit, Ask again for the entrance.',
      props: {},
    },
    "dot-grow": {
      note: "Indicator B: the dot and the words with no fill. Quieter, but it reads as a caption of the card, not a state.",
      props: { look: "dot" },
    },
    "label-grow": {
      note: "Indicator C: the words alone in the attention colour. Lightest; on a light theme the yellow text is hard to read.",
      props: { look: "label" },
    },
    "pill-rise": {
      note: "Motion B: the grow plus an 8px rise from the composer. More movement for the same change; the card slides against the transcript moving the other way.",
      props: { motion: "rise" },
    },
    "pill-fade": {
      note: "Motion C: a fade only. The card's room opens in one frame and closes in one frame after the fade, so the transcript jumps twice.",
      props: { motion: "fade" },
    },
  },
});

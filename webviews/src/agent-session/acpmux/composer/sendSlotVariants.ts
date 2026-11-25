// The send slot's morph sets for the coordinator to choose between (gallery
// agent-pane.composer-send-slot-states). Each is a whole SlotMorphSet, so the completeness detector
// (send-slot-transitions-complete) checks every one. Only `scale` is shipped; none flips a default.
import { MOTION_MS } from "../../../motion/scale.generated";
import {
  SLOT_DRAWN,
  SLOT_TRANSITIONS,
  type SlotDrawn,
  type SlotMorphSet,
  type SlotTransition,
} from "./sendSlotTransitions";

const sendSide = (glyph: SlotDrawn) => glyph === "return" || glyph === "arrow";
const stopSide = (glyph: SlotDrawn) => glyph === "stop";

/// A copy of `set` with each glyph row `change` returns replaced.
function remap(
  set: SlotMorphSet,
  change: (from: SlotDrawn, to: SlotDrawn, row: SlotTransition) => SlotTransition | undefined,
): SlotMorphSet {
  const morphs = {} as SlotMorphSet["morphs"];
  for (const from of SLOT_DRAWN) {
    morphs[from] = { ...set.morphs[from] };
    for (const to of SLOT_DRAWN) morphs[from][to] = change(from, to, set.morphs[from][to]) ?? set.morphs[from][to];
  }
  return { ...set, morphs };
}

export const SLOT_VARIANT_IDS = ["scale", "path-send-stop", "sending-ring", "enter-on-type"] as const;
export type SlotVariantId = (typeof SLOT_VARIANT_IDS)[number];

export const SLOT_VARIANTS: Record<SlotVariantId, { set: SlotMorphSet; note: string }> = {
  scale: {
    set: SLOT_TRANSITIONS,
    note: `Shipped. One crossfade + scale (70% to 100%) on the standard ${MOTION_MS.standard} ms step everywhere the glyph changes; ↵ appears and leaves at once with the draft; a send in Claude's look leaves the slot empty until its Stop grows in.`,
  },
  "path-send-stop": {
    set: remap(SLOT_TRANSITIONS, (from, to, row) =>
      row.morph === "crossfade" && ((sendSide(from) && stopSide(to)) || (stopSide(from) && sendSide(to)))
        ? { ...row, morph: "path" }
        : undefined,
    ),
    note: "Send and Stop bend one stroke into the other (↵ or ↑ into the square and back); every other change (Stop to its stopping ring, Resume) keeps the crossfade + scale.",
  },
  "sending-ring": {
    set: {
      ...SLOT_TRANSITIONS,
      glyphs: { ...SLOT_TRANSITIONS.glyphs, sending: { claude: "pending", codex: "pending" } },
    },
    note: "While the host has not taken the prompt, the slot shows a ring instead of an empty slot (Claude's look) or the dimmed ↑ (Codex's); the ring crossfades into the turn's Stop.",
  },
  "enter-on-type": {
    set: remap(SLOT_TRANSITIONS, (from, to) =>
      from === "none" && (to === "return" || to === "play")
        ? {
            morph: "enter",
            step: "standard",
            ease: "ease-out",
            reduced: "swap",
            why: "↵ (or Resume) grows in as the first letter lands, as the send's Stop does",
          }
        : undefined,
    ),
    note: "Claude's look: ↵ grows in with the first letter (as the send's Stop grows in) instead of appearing at once. Leaving stays instant: the button is gone in that frame.",
  },
};

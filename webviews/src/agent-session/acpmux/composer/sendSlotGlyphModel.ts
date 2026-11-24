import { type SendStopMorphArm } from "./sendStopMorph.experiment";
import { MOTION_MS } from "../../../motion/scale.generated";
import {
  animates,
  glyphTransition,
  SLOT_TRANSITIONS,
  type SlotGlyph,
  type SlotMorphSet,
  type SlotState,
  type SlotTransition,
} from "./sendSlotTransitions";

export { SLOT_GLYPHS, type SlotGlyph } from "./sendSlotTransitions";

/// What the slot drew last, kept by the composer across the Send and Stop buttons' remounts.
export type SlotMemory = {
  scope?: string;
  /// When `scope` began (a chat switch or a chat read).
  since: number;
  /// The glyph on screen now, if any, and the state it was drawn for (when its button said).
  glyph?: SlotGlyph;
  state?: SlotState;
  /// The glyph that left the slot with nothing in its place (Claude's look clears ↵ on a send before
  /// the turn's Stop arrives), and when.
  left?: SlotGlyph;
  leftAt?: number;
};

/// The motion scale's structural step (foundations.md, --cmux-motion-standard).
export const MORPH_MS = MOTION_MS.standard;
/// What leaves the slot fades on the motion scale's leaving step (foundations.md, --cmux-motion-quick).
export const LEAVE_MS = MOTION_MS.quick;
/// Stop's pulse when a turn starts again while it lingers (turnPresence.ts): the structural step.
export const PULSE_MS = MOTION_MS.standard;
/// A change this soon after a chat switch or read is the chat's state arriving, not a change.
export const SETTLE_MS = 300;
/// Claude's look empties the slot on a send until the turn's Stop arrives: a Stop this soon after
/// the ↵ left comes in as the send's Stop.
export const GAP_MS = 400;

/// The page clock morphs measure against.
export const now = () => globalThis.performance?.now() ?? Date.now();

export function newSlotMemory(scope?: string): SlotMemory {
  return { ...(scope !== undefined ? { scope } : {}), since: now() };
}

/// A scope change (chat switch, chat read) starts a new settle window and forgets the last glyph.
export function noteScope(memory: SlotMemory, scope: string | undefined, at = now()): void {
  if (memory.scope === scope) return;
  memory.scope = scope;
  memory.since = at;
  delete memory.glyph;
  delete memory.state;
  delete memory.left;
  delete memory.leftAt;
}

export type Morph = { from?: SlotGlyph; arm: SendStopMorphArm; transition: SlotTransition };

/// What `glyph`, drawn now in `scope` for `state`, morphs from, read from the morph set's tables
/// (sendSlotTransitions.ts): the glyph still on screen (a direct swap), or nothing with an `enter`
/// row (a `gap` one only when the slot emptied just now: the send's own Stop). Undefined: draw it at
/// once (the same glyph, an `instant` row, the first draw, or within SETTLE_MS of a chat switch or
/// read).
export function morphFrom(
  memory: SlotMemory,
  scope: string | undefined,
  glyph: SlotGlyph,
  at = now(),
  state?: SlotState,
  set: SlotMorphSet = SLOT_TRANSITIONS,
): { from?: SlotGlyph; transition: SlotTransition } | undefined {
  if (memory.scope !== scope || at - memory.since < SETTLE_MS) return undefined;
  if (memory.glyph) {
    const transition = glyphTransition(set, memory.glyph, glyph, { from: memory.state, to: state });
    return animates(transition) && transition.when !== "gap" ? { from: memory.glyph, transition } : undefined;
  }
  // The slot was empty: an `enter` row grows the glyph in. A `gap` row only for the send's own
  // Stop: a glyph left at most GAP_MS ago, and it would itself have morphed into this one.
  // An empty slot is Claude's look at rest, whatever state was drawn before it emptied.
  const transition = glyphTransition(set, "none", glyph, { from: "idle", to: state });
  if (!animates(transition)) return undefined;
  // Stop into an empty slot fades in (`enterStop`): the turn's Stop shows only once it has held
  // (turnPresence.ts), so its arrival is a real change, never a flicker. A Stop that left and comes
  // back is the same Stop: drawn at once.
  if ((glyph === "stop" || glyph === "stopping") && (memory.left === "stop" || memory.left === "stopping"))
    return undefined;
  if (transition.when === "gap") {
    if (!memory.left || memory.leftAt === undefined || at - memory.leftAt > GAP_MS) return undefined;
    if (!animates(glyphTransition(set, memory.left, glyph))) return undefined;
  }
  return { transition };
}

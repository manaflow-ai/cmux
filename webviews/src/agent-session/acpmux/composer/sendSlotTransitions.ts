// The composer's send slot as one known state machine (design/composer-send-slot.md). Leo,
// 2026-11-22: "idle to send to stop to whatever we need those to be like... known."
//
// Three tables, read by SendSlotGlyph.tsx at run time, so the spec is the implementation:
// - SLOT_STATES: what each state of the slot draws, in Claude's look and Codex's;
// - morphs: for every ordered pair of drawn glyphs, the motion between them, its duration token
//   and easing token from motion/scale.generated.ts, and its Reduce Motion behaviour;
// - states: for every ordered pair of states, whether it can happen, and the morph a state pair
//   takes over its glyphs' (into and out of `unsend`: the sibling `unpop`).
// Detector `send-slot-transitions-complete` (sendSlotTransitions.test.ts) fails when a glyph or a
// state is added without its rows, or a reachable pair resolves to no morph.
import type { MotionStep } from "../../../motion/scale.generated";

/// Every glyph the slot draws (SendSlotGlyph.tsx GlyphIcon). A glyph added here needs its rows
/// below. `pending` is the send's ring, drawn only by a gallery morph set (sendSlotVariants.ts).
export const SLOT_GLYPHS = ["stop", "stopping", "return", "arrow", "play", "pending"] as const;
export type SlotGlyph = (typeof SLOT_GLYPHS)[number];

/// The slot's states. `queued` is a prompt held behind a paused queue (the slot's Resume ▶); a
/// prompt held behind a running turn keeps `stop` (turnHandover.ts), and one held behind the
/// folder's trust question keeps its draft's `send-ready` glyph, disabled (only its ink changes).
/// `unsend` is a queued prompt pulled back into the composer before it was sent.
export const SLOT_STATE_LIST = ["idle", "send-ready", "sending", "stop", "stopping", "queued", "unsend"] as const;
export type SlotState = (typeof SLOT_STATE_LIST)[number];
export type SlotLook = "claude" | "codex";
export const SLOT_LOOKS: readonly SlotLook[] = ["claude", "codex"];
/// What the slot draws: a glyph, or `none` (no button: Claude's look with nothing to send).
export type SlotDrawn = SlotGlyph | "none";
export const SLOT_DRAWN: readonly SlotDrawn[] = ["none", ...SLOT_GLYPHS];

/// The motions. `crossfade` draws the old glyph leaving as the new one arrives, in the arm of
/// experiment send-stop-morph (scale by default); `path` bends one stroke into the other; `enter`
/// draws the new glyph arriving with nothing leaving; `unpop` is the un-pop's (the sibling
/// composer-unpop lane's keyframes, `[data-send-unpop]`); `none` and `instant` draw nothing.
export type SlotMorph = "crossfade" | "path" | "enter" | "unpop" | "none" | "instant";
export type SlotEase = "ease-out";

export type SlotTransition =
  | {
      morph: "crossfade" | "path" | "enter" | "unpop";
      /// Its duration: a step of the motion scale (MOTION_MS).
      step: MotionStep;
      /// Its curve: `ease-out` is MOTION_EASE_OUT (--cmux-ease-out).
      ease: SlotEase;
      /// Under Reduce Motion (or motion off, or a hidden page): the new glyph in one frame, no copy.
      reduced: "swap";
      /// `gap`: only when the slot emptied at most GAP_MS ago (the send's own Stop, Claude's look).
      when?: "gap";
      why: string;
    }
  | { morph: "none" | "instant"; why: string };

export type StateRow =
  | { reachable: false; why: string }
  /// Reachable; with `morph` it takes that transition over the glyphs' own row.
  | { reachable: true; why: string; morph?: SlotTransition };

export type SlotMorphSet = {
  glyphs: Record<SlotState, Record<SlotLook, SlotDrawn>>;
  morphs: Record<SlotDrawn, Record<SlotDrawn, SlotTransition>>;
  states: Record<SlotState, Record<SlotState, StateRow>>;
};

const crossfade = (why: string): SlotTransition => ({
  morph: "crossfade",
  step: "standard",
  ease: "ease-out",
  reduced: "swap",
  why,
});
const same: SlotTransition = { morph: "none", why: "same glyph" };
const leaves: SlotTransition = {
  morph: "instant",
  why: "the button leaves the bar in the frame its draft empties; there is no button left to draw a copy in",
};
const sendToStop = crossfade("a turn starts: Send becomes Stop (Leo 2026-11-07)");
const stopToSend = crossfade("a turn ends, or the first letter is typed mid-turn: Stop becomes Send");
const toResume = crossfade("the draft empties while the queue is paused: Send becomes Resume");
const fromResume = crossfade("a letter typed while the queue is paused: Resume becomes Send");
const enterStop: SlotTransition = {
  morph: "enter",
  step: "standard",
  ease: "ease-out",
  reduced: "swap",
  why: "Claude's look draws nothing at rest; the turn's Stop shows only once it has held (turnPresence.ts), so it grows in, the send's own Stop and a turn started elsewhere alike (Leo 2026-11-22: \"we ought to have a better fade in/fade out\")",
};
const unpop = (why: string): SlotTransition => ({
  morph: "unpop",
  step: "standard",
  ease: "ease-out",
  reduced: "swap",
  why,
});

/// The motion between every two drawn glyphs.
const MORPHS: SlotMorphSet["morphs"] = {
  none: {
    none: same,
    return: { morph: "instant", why: "↵ appears in the frame the first letter lands, as typing does" },
    arrow: { morph: "instant", why: "Codex's ↑ is always drawn: it only appears on a first draw or a look switch" },
    play: { morph: "instant", why: "Resume appears with the paused queue, in the frame it pauses" },
    stop: enterStop,
    stopping: enterStop,
    pending: { morph: "instant", why: "the send's ring appears in the frame the draft empties" },
  },
  return: {
    none: leaves,
    return: same,
    arrow: { morph: "instant", why: "only on a look switch, a setting change" },
    play: toResume,
    stop: sendToStop,
    stopping: sendToStop,
    pending: crossfade("the send is held until the host takes it: ↵ becomes the ring"),
  },
  arrow: {
    none: leaves,
    return: { morph: "instant", why: "only on a look switch, a setting change" },
    arrow: same,
    play: toResume,
    stop: sendToStop,
    stopping: sendToStop,
    pending: crossfade("the send is held until the host takes it: ↑ becomes the ring"),
  },
  play: {
    none: leaves,
    return: fromResume,
    arrow: fromResume,
    play: same,
    stop: crossfade("Resume runs the queue: its turn's Stop"),
    stopping: crossfade("Resume runs the queue: its turn's Stop"),
    pending: crossfade("Resume is held until the host takes it"),
  },
  stop: {
    none: leaves,
    return: stopToSend,
    arrow: stopToSend,
    play: crossfade("the turn ends with the queue paused: Stop becomes Resume"),
    stop: same,
    stopping: crossfade("Stop is pressed: the square becomes the stopping ring"),
    pending: crossfade("a send held mid-turn"),
  },
  stopping: {
    none: leaves,
    return: stopToSend,
    arrow: stopToSend,
    play: crossfade("the stopped turn ends with the queue paused: Resume"),
    stop: crossfade("Stop did not take: the square comes back"),
    stopping: same,
    pending: crossfade("a send held while the turn stops"),
  },
  pending: {
    none: leaves,
    return: crossfade("the host refused the send: the draft and its ↵ come back"),
    arrow: crossfade("the host took the send with no turn, or refused it"),
    play: crossfade("the host took the send into a paused queue"),
    stop: crossfade("the host took the send: its turn's Stop"),
    stopping: crossfade("the host took the send and its turn is stopping"),
    pending: same,
  },
};

const no = (why: string): StateRow => ({ reachable: false, why });
const yes = (why: string, morph?: SlotTransition): StateRow => ({ reachable: true, why, ...(morph ? { morph } : {}) });

/// Every ordered pair of states: can it happen, and does it take its own morph.
const STATES: SlotMorphSet["states"] = {
  idle: {
    idle: yes("a redraw"),
    "send-ready": yes("the first letter, or an attachment"),
    sending: no("a send needs a draft"),
    stop: yes("a turn starts elsewhere, or a held prompt starts"),
    stopping: no("Stop needs a running turn's Stop first"),
    queued: yes("the queue pauses"),
    unsend: yes("a paused queue's prompt is pulled back", unpop("a queued prompt comes back into the composer")),
  },
  "send-ready": {
    idle: yes("the draft is deleted"),
    "send-ready": yes("typing"),
    sending: yes("Return, with no turn running"),
    stop: yes("Return mid-turn (steer or queue), or the draft deleted mid-turn"),
    stopping: yes("the draft deleted while the turn stops"),
    queued: yes("the draft deleted while the queue is paused"),
    unsend: yes("a queued prompt is pulled back into a draft", unpop("a queued prompt comes back into the composer")),
  },
  sending: {
    idle: yes("the host took it and no turn ran"),
    "send-ready": yes("the host refused it: the draft comes back"),
    sending: yes("a redraw"),
    stop: yes("the host took it: its turn starts"),
    stopping: no("Stop needs a running turn's Stop first"),
    queued: yes("the host took it into a paused queue"),
    unsend: no("a held send is not in the queue yet"),
  },
  stop: {
    idle: yes("the turn ends"),
    "send-ready": yes("the first letter typed mid-turn"),
    sending: no("mid-turn a send goes from send-ready to stop"),
    stop: yes("a redraw, or the first Esc of the double press (ink only)"),
    stopping: yes("Stop pressed, or the second Esc"),
    queued: yes("the turn ends with the queue paused"),
    unsend: yes("a queued prompt pulled back mid-turn", unpop("a queued prompt comes back into the composer")),
  },
  stopping: {
    idle: yes("the stopped turn ends"),
    "send-ready": yes("a letter typed while the turn stops"),
    sending: no("mid-turn a send goes from send-ready to stop"),
    stop: yes("Stop did not take (the host's error)"),
    stopping: yes("Stop pressed again: Stop is sent again"),
    queued: yes("the stopped turn ends with the queue paused"),
    unsend: yes(
      "a queued prompt pulled back while the turn stops",
      unpop("a queued prompt comes back into the composer"),
    ),
  },
  queued: {
    idle: yes("the queue is cleared"),
    "send-ready": yes("a letter typed"),
    sending: no("Resume runs the queue; it does not send a draft"),
    stop: yes("Resume: the queue's turn starts"),
    stopping: no("Stop needs a running turn's Stop first"),
    queued: yes("a redraw"),
    unsend: yes("the paused prompt pulled back", unpop("a queued prompt comes back into the composer")),
  },
  unsend: {
    // The un-pop runs only where the glyph changes and its button stays (slotTransition): where
    // the button leaves or keeps its glyph, the glyphs' own row.
    idle: yes("the pulled-back draft deleted", unpop("the un-pop's own exit")),
    "send-ready": yes("the un-pop ends: it is a draft (the same glyph)"),
    sending: yes("the pulled-back draft sent again", unpop("the un-pop's own exit")),
    stop: yes("the pulled-back draft deleted mid-turn", unpop("the un-pop's own exit")),
    stopping: yes("the pulled-back draft deleted while the turn stops", unpop("the un-pop's own exit")),
    queued: yes("the pulled-back draft deleted while the queue is paused", unpop("the un-pop's own exit")),
    unsend: yes("a redraw"),
  },
};

/// The shipped morph set: what the slot draws in each state, and every motion between.
export const SLOT_TRANSITIONS: SlotMorphSet = {
  glyphs: {
    idle: { claude: "none", codex: "arrow" },
    "send-ready": { claude: "return", codex: "arrow" },
    // The composer empties on Return; Codex's ↑ stays, dimmed, until the host takes the prompt.
    sending: { claude: "none", codex: "arrow" },
    stop: { claude: "stop", codex: "stop" },
    stopping: { claude: "stopping", codex: "stopping" },
    queued: { claude: "play", codex: "play" },
    unsend: { claude: "return", codex: "arrow" },
  },
  morphs: MORPHS,
  states: STATES,
};

/// The transition from `from` to `to` drawn in `look`: the state pair's own morph if it has one,
/// else the glyphs'. Undefined for a pair that cannot happen.
export function slotTransition(
  set: SlotMorphSet,
  from: SlotState,
  to: SlotState,
  look: SlotLook,
): SlotTransition | undefined {
  const row = set.states[from][to];
  if (!row.reachable) return undefined;
  const a = set.glyphs[from][look];
  const b = set.glyphs[to][look];
  // A state's own morph runs only where the glyph changes and a button stays to draw it in.
  if (row.morph && a !== b && b !== "none") return row.morph;
  return set.morphs[a][b];
}

/// The transition between two drawn glyphs, with the states they were drawn for when known.
export function glyphTransition(
  set: SlotMorphSet,
  from: SlotDrawn,
  to: SlotDrawn,
  states?: { from?: SlotState | undefined; to?: SlotState | undefined },
): SlotTransition {
  const row = states?.from && states.to ? set.states[states.from][states.to] : undefined;
  if (row?.reachable && row.morph && from !== to && to !== "none") return row.morph;
  return set.morphs[from][to];
}

export function animates(
  transition: SlotTransition,
): transition is Extract<SlotTransition, { morph: "crossfade" | "path" | "enter" | "unpop" }> {
  return transition.morph !== "none" && transition.morph !== "instant";
}

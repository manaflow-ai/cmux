import { type SendStopMorphArm } from "./sendStopMorph.experiment";

export type SlotGlyph = "stop" | "stopping" | "return" | "arrow";

/// What the slot drew last, kept by the composer across the Send and Stop buttons' remounts.
export type SlotMemory = {
  scope?: string;
  /// When `scope` began (a chat switch or a chat read).
  since: number;
  /// The glyph on screen now, if any.
  glyph?: SlotGlyph;
  /// The glyph that left the slot with nothing in its place (Claude's look clears ↵ on a send before
  /// the turn's Stop arrives), and when.
  left?: SlotGlyph;
  leftAt?: number;
};

/// The motion scale's structural step (foundations.md, --cmux-motion-standard).
export const MORPH_MS = 180;
/// A change this soon after a chat switch or read is the chat's state arriving, not a change.
export const SETTLE_MS = 300;
/// Claude's look empties the slot on a send until the turn's Stop arrives: a Stop this soon after
/// the ↵ left comes in as the send's Stop.
export const GAP_MS = 400;

/// The page clock morphs measure against.
export const now = () => globalThis.performance?.now() ?? Date.now();
const side = (glyph: SlotGlyph) => (glyph === "stop" || glyph === "stopping" ? "stop" : "send");

export function newSlotMemory(scope?: string): SlotMemory {
  return { ...(scope !== undefined ? { scope } : {}), since: now() };
}

/// A scope change (chat switch, chat read) starts a new settle window and forgets the last glyph.
export function noteScope(memory: SlotMemory, scope: string | undefined, at = now()): void {
  if (memory.scope === scope) return;
  memory.scope = scope;
  memory.since = at;
  delete memory.glyph;
  delete memory.left;
  delete memory.leftAt;
}

export type Morph = { from?: SlotGlyph; arm: SendStopMorphArm };

/// What `glyph`, drawn now in `scope`, morphs from: the glyph still on screen (a direct swap), or
/// the one that left the slot just now (the send's gap), or nothing (draw it at once).
export function morphFrom(
  memory: SlotMemory,
  scope: string | undefined,
  glyph: SlotGlyph,
  at = now(),
): { from?: SlotGlyph } | undefined {
  if (memory.scope !== scope || at - memory.since < SETTLE_MS) return undefined;
  if (memory.glyph) return side(memory.glyph) !== side(glyph) ? { from: memory.glyph } : undefined;
  if (memory.left && memory.leftAt !== undefined && side(memory.left) !== side(glyph) && at - memory.leftAt <= GAP_MS)
    return {};
  return undefined;
}

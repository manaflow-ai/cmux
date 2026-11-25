// What a look's thinking glyph (thinkingLook.ts `glyph`, a `cmux.particles/1` document) plays, and
// where it sits. Pure, so the trigger map is tested on its own (Leo, 2026-11-19: "the dots and the way
// it moves changes a lot"): the document's `triggers` name acpmux tool kinds (`read edit delete move
// search execute think fetch switch_mode other`) and session states (`sendMessage turnStart thinking
// idle cursor`); the player plays `cycle` for a kind the document does not name.
//
// The live status line (ThinkingRow.tsx) says what the agent does now; it publishes that trigger here,
// so Jump to latest, which knows only that the agent works, plays the same program in step with it.
import { useSyncExternalStore } from "react";
import type { Choreography } from "../../../apps/scene/choreography";

/** The live line's state, as ThinkingRow has it (model.ts `AcpmuxRow`). */
export type GlyphActivity = {
  /** The prompt waits for its agent to start. */
  starting?: boolean;
  /** The acpmux tool kind of the call in flight (`execute`, `read`, ...). */
  kind?: string;
  /** The call in flight sends another agent a message. */
  sendTo?: string;
  liveState?: "subagents" | "writing" | "compacting";
};

/** The trigger for the agent's current activity: a call's own kind wins; with none, it thinks. */
export function glyphTrigger(activity: GlyphActivity): string {
  if (activity.starting) return "turnStart";
  if (activity.sendTo) return "sendMessage";
  if (activity.kind) return activity.kind;
  // Writing its reply, compacting, or waiting on subagents: no tool kind; the document's `cycle`.
  if (activity.liveState) return "other";
  return "thinking";
}

/** Points: the box a glyph's dots stay inside at `size` points a dot, from every frame and site. */
export function glyphExtent(doc: Choreography, size = doc.size): { width: number; height: number } {
  let x = 0;
  let y = 0;
  let scale = 1;
  for (const phase of doc.phases.values()) {
    for (const frame of phase.frames) {
      for (const dot of frame.dots) {
        x = Math.max(x, Math.abs(dot.x));
        y = Math.max(y, Math.abs(dot.y));
        scale = Math.max(scale, dot.s);
      }
    }
    for (const [sx, sy] of phase.generator?.sites ?? []) {
      x = Math.max(x, Math.abs(sx));
      y = Math.max(y, Math.abs(sy));
    }
    for (const frame of phase.generator?.lifeFrames ?? []) scale = Math.max(scale, frame.s);
  }
  const reach = (size * scale) / 2;
  return { width: Math.ceil(2 * (x + reach)), height: Math.ceil(2 * (y + reach)) };
}

let liveTrigger = "thinking";
const listeners = new Set<() => void>();

/** The transcript's live line says what the agent does now. */
export function setLiveGlyphTrigger(trigger: string): void {
  if (trigger === liveTrigger) return;
  liveTrigger = trigger;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
const snapshot = () => liveTrigger;

/** The live line's trigger (Jump to latest plays it). */
export const useLiveGlyphTrigger = (): string => useSyncExternalStore(subscribe, snapshot, snapshot);

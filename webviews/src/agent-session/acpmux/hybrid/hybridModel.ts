// A hybrid chat's cloud state as the page draws it (RFD 0075). The rules (who holds a slot, who
// waits, what moves when the computer goes away) are Rust's: cmux-cloud-start-core `moves/priority.rs`
// computes this view and the page only reads it.

/// Where the person pinned the chat. `auto`: it runs where it should.
export type HybridPin = "auto" | "cloud" | "local";

/// The cloud button's state for one chat.
export type HybridView = {
  /// The button is on: the chat holds a slot, so it keeps running in Cloud when this Mac goes away.
  lit: boolean;
  /// Turned on, but every slot is held by an older choice: it takes the next free one.
  waiting?: boolean;
  pin: HybridPin;
  /// Where the chat runs now.
  at: "local" | "cloud";
  /// Slots in use and in the plan.
  used: number;
  total: number;
};

/// The toggle's "on" look. `rainbow`: Leo's rainbow cloud. `sky`: one accent fill. `aurora`: a quiet
/// cloud over a soft rainbow halo.
export type HybridLook = "rainbow" | "sky" | "aurora";

/// A chat nobody touched: Auto, off.
export const HYBRID_OFF: HybridView = { lit: false, pin: "auto", at: "local", used: 0, total: 3 };

/// The view after the person clicks the button, shown at once while the write is in flight.
export function clicked(view: HybridView): HybridView {
  if (view.lit || view.waiting) {
    return { ...view, lit: false, waiting: false, used: Math.max(0, view.used - (view.lit ? 1 : 0)) };
  }
  if (view.used >= view.total) return { ...view, waiting: true };
  return { ...view, lit: true, used: view.used + 1 };
}

/// Parallel start: a chat with Cloud chosen starts on this Mac at once while its cloud computer
/// boots, then its home moves there at a tool boundary or the turn's end. The steps the button shows:
/// `booting` (running here, the cloud computer starting), `ready` (it is up; the move waits for a
/// pause), `moving`, `live` (in Cloud) and `failed` (it did not start; the chat keeps running here).
export type HybridStart = "booting" | "ready" | "moving" | "live" | "failed";

/// How the button shows the steps before `live`. `fill`: the cloud fills left to right. `breathe`:
/// its outline takes the look's color and breathes. `words`: the glyph stays quiet and the name
/// beside it steps through "Starting Here", "Cloud Ready", "Moving", "In Cloud".
export type HybridStartLook = "fill" | "breathe" | "words";

export const START_NAMES = {
  booting: "hybrid.start.booting",
  ready: "hybrid.start.ready",
  moving: "hybrid.start.moving",
  live: "hybrid.start.live",
  failed: "hybrid.start.failed",
} as const;
export const START_HELP = {
  booting: "hybrid.start.booting.help",
  ready: "hybrid.start.ready.help",
  moving: "hybrid.start.moving.help",
  live: "hybrid.keepRunning.help",
  failed: "hybrid.start.failed.help",
} as const;

/// A chat's parallel-start state as the daemon answers it (cmux-cloud-start-core `hybrid`, FFI op
/// `cloud_hybrid_step`, the answer's `state`). `home`: where the chat runs now. `cloud`: its cloud
/// computer's step. `since`: when `cloud` last changed, in monotonic milliseconds. `reason`: why it
/// failed. The answer also carries `held`, the ids of prompts held while the chat moves; the button
/// does not draw them. With the feature off (`cloud_hybrid_enabled`) the control gets no state at
/// all and draws nothing new.
export type HybridStartState = {
  home: "here" | "cloud";
  cloud: "none" | HybridStart;
  since: number;
  reason?: string | null;
};

/// The reason the daemon gives when the person kept the chat here. That is their choice, not a
/// failure, so the button draws it as plain off.
const STOPPED = "stopped";

const STEPS: readonly HybridStart[] = ["booting", "ready", "moving", "live", "failed"];

/// The one place that reads the daemon's fields: the step the button draws for a chat's start
/// state. Nothing for no state, `none`, a chat the person kept here, or a step this build does not
/// know, so a newer daemon never draws a wrong step.
export function startOf(state?: HybridStartState | null): { step?: HybridStart; reason?: string } {
  const step = state ? STEPS.find((known) => known === state.cloud) : undefined;
  if (!step || !state) return {};
  if (step !== "failed") return { step };
  if (state.reason === STOPPED) return {};
  return state.reason ? { step, reason: state.reason } : { step };
}

/// The button is lit only once the chat is in Cloud; before that the start steps draw instead.
export function startSettled(start?: HybridStart): boolean {
  return start === undefined || start === "live";
}

// A hybrid chat's cloud state as the page draws it (RFD 0078). The rules (who holds a slot, who
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

/// Why the control cannot change the chat's place now (a first run's cases). The app decides which
/// applies (cmux-cloud-start-core: the account, the plan, `Admit::NoCloud`, the connection, the
/// last move); the control only names it and hands a click back.
export type HybridBlockedWhy =
  | "signed-out"
  | "no-plan"
  | "no-cloud"
  | "hours-spent"
  | "trial-ended"
  | "offline"
  | "move-failed"
  /// The chat paused because this Mac slept; a click turns on Keep Running instead.
  | "slept"
  /// Cloud's free trials are full for today.
  | "trial-full";
export type HybridBlocked = { why: HybridBlockedWhy };

/// A chat that holds one of the plan's slots (priority.rs `Holder`, from `Admit::Full { holders }`).
export type SlotHolder = { session: string; title: string };

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

/// A hybrid start's machine side (RFD 0078, "the start"; cmux-cloud-start-core `hybrid::Cloud`, as
/// its `Effect::Show` sends it). A chat with Cloud chosen starts on this Mac at once while its
/// machine boots, then moves at a tool boundary or turn end. The button alone shows where it is.
/// Rust decides every step; the page only draws the one it is told.
export const HYBRID_START_STATES = ["booting", "ready", "moving", "live", "failed"] as const;
export type HybridStartState = (typeof HYBRID_START_STATES)[number];
export type HybridStart = {
  cloud: HybridStartState;
  /// Why `failed`, in Rust's word (the chat is still running here).
  reason?: string;
};

/// `place.start`, or none when the app sends none or `none` (no hybrid start began).
export function hybridStartOf(value: unknown): HybridStart | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  if (!(HYBRID_START_STATES as readonly unknown[]).includes(raw.cloud)) return undefined;
  const cloud = raw.cloud as HybridStartState;
  return typeof raw.reason === "string" && raw.reason && cloud === "failed" ? { cloud, reason: raw.reason } : { cloud };
}

/// Where the chat's one writer is now: here until the move commits.
export function startRunsHere(start: HybridStart): boolean {
  return start.cloud !== "live";
}

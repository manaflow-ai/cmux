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

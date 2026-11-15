/// The momentum hold (`holdMomentum`, `installMomentumHold`). A leaf module with no imports, so
/// `links.ts` can hold a reveal's momentum without pulling the transcript's model (and its fonts)
/// into every page that copies a link.

/// A trackpad fling's momentum after a scroll made from code (Leo 2026-11-12: "it doesn't, like,
/// break the momentum and jump to bottom immediately"). WebKit keeps sending the fling's momentum as
/// wheel events after a write to scrollTop, and the DOM tells nothing of their phase: the next one
/// ended Jump to latest as the reader's input, let go of the latest row, and the browser glided on
/// from where the jump put the view. Momentum is a stream of wheel events a frame or so apart that
/// keep their direction and decay; the reader's next gesture comes after a pause, turns round or
/// grows. The pause is read from the events' own times (WebKit stamps a wheel with the platform
/// event's time), so a frame the page spent rendering the jump is no pause. Only the stream under way as the scroll from code started is held: no listener sees it (a
/// window capture listener installed first stops it), and the view is put back where that scroll
/// put it. Its events stay uncancelable (WebKit latches a gesture's first event's handling), so the
/// pin, not preventDefault, is what keeps the view still. Passive throughout: no wheel waits on the page.
export const MOMENTUM_GAP_MS = 80;
/// A scroll that comes this long after the hold started and the last wheel arrived is no momentum's.
const MOMENTUM_ARRIVAL_MS = 250;
/// The longest a fling's momentum is held, however it decays.
const MOMENTUM_MAX_MS = 4000;
type MomentumState = {
  /// The last wheel over the scroller: when it arrived, its own time, and its vertical delta.
  at: number;
  stamp: number;
  deltaY: number;
  hold?: { target: () => number; since: number; echo: boolean };
};
const momentum = new WeakMap<HTMLElement, MomentumState>();

function continuesMomentum(event: WheelEvent, last: MomentumState): boolean {
  if (event.timeStamp - last.stamp > MOMENTUM_GAP_MS || event.ctrlKey || event.deltaMode !== 0) return false;
  if (!event.deltaY) return true;
  return (
    Math.sign(event.deltaY) === Math.sign(last.deltaY) && Math.abs(event.deltaY) <= Math.abs(last.deltaY) * 1.25 + 1
  );
}

/// The hold still on: momentum keeps arriving, and not for longer than any fling's. A wheel event
/// itself (`arrived`) answers by its own time instead (`continuesMomentum`): a page busy with the
/// jump's rendering delivers the stream late, not paused.
function heldMomentum(state: MomentumState | undefined, now = performance.now(), arrived = false) {
  const hold = state?.hold;
  if (!state || !hold) return undefined;
  if ((!arrived && now - Math.max(state.at, hold.since) > MOMENTUM_ARRIVAL_MS) || now - hold.since > MOMENTUM_MAX_MS) {
    state.hold = undefined;
    return undefined;
  }
  return hold;
}

/// Watches the wheel over `node` so a scroll from code can hold the momentum under way
/// (`holdMomentum`). Install before any other wheel listener on the page's window.
export function installMomentumHold(node: HTMLElement, scrolling: (node: HTMLElement) => boolean): () => void {
  const state: MomentumState = { at: -Infinity, stamp: -Infinity, deltaY: 0 };
  momentum.set(node, state);
  const page = node.ownerDocument.defaultView ?? window;
  const wheel = (event: WheelEvent) => {
    if (!node.contains(event.target as Node | null)) return;
    const now = performance.now();
    const held = heldMomentum(state, now, true) && continuesMomentum(event, state);
    if (!held) state.hold = undefined;
    else event.stopImmediatePropagation();
    state.at = now;
    state.stamp = event.timeStamp;
    if (event.deltaY || !held) state.deltaY = event.deltaY;
  };
  // Any other input is the reader's own: the view is theirs again.
  const release = () => {
    state.hold = undefined;
  };
  // Before the transcript's own scroll handler (capture runs first at the target): momentum that
  // moved the view moves it back, and neither that scroll nor the one the write back fires is the
  // reader's. A scroll from code still running owns the offset (its rebase absorbs the momentum).
  const scroll = (event: Event) => {
    const hold = heldMomentum(state);
    if (!hold || scrolling(node)) return;
    const target = hold.target();
    if (Math.abs(node.scrollTop - target) > 0.5) {
      node.scrollTop = target;
      hold.echo = true;
      event.stopImmediatePropagation();
    } else if (hold.echo) {
      hold.echo = false;
      event.stopImmediatePropagation();
    }
  };
  page.addEventListener("wheel", wheel, { capture: true, passive: true });
  for (const name of ["pointerdown", "touchstart", "keydown"]) page.addEventListener(name, release, true);
  node.addEventListener("scroll", scroll, { capture: true, passive: true });
  return () => {
    page.removeEventListener("wheel", wheel, true);
    for (const name of ["pointerdown", "touchstart", "keydown"]) page.removeEventListener(name, release, true);
    node.removeEventListener("scroll", scroll, true);
    if (momentum.get(node) === state) momentum.delete(node);
  };
}

/// A scroll from code just moved `node` to `target()`: the momentum of a fling under way as it
/// started is held there until it ends (`installMomentumHold`). Whether a stream is under way is
/// the next wheel's to say, by its own time against the last one's: none, and the hold lapses.
export function holdMomentum(node: HTMLElement, target: () => number): void {
  const state = momentum.get(node);
  const now = performance.now();
  if (!state || now - state.at > MOMENTUM_MAX_MS || !state.deltaY) return;
  state.hold = { target, since: now, echo: false };
}

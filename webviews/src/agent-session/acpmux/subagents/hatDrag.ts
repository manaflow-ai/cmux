// The pointer side of the hat's row drag (hatRows.ts): a press on the hat's top bar or rim
// (SubagentTray.tsx) or on its pull tab (TrayPullTab.tsx) that moves past the slop becomes a drag.
// The drag captures the pointer on the document's root, never on the control it began on: from the
// pull tab, the tab goes as the hat comes back, and a capture on it would end the drag there. Each
// whole row the pointer crosses is one change to the chat's hat (trayFoldMemory.ts), so the hat,
// the composer under it, the transcript's room and Jump to latest all move in the frame that draws
// it (VirtualTranscript.tsx measures the dock in its ResizeObserver). The rubber band past one row
// is a style the hat sets itself (`onBand`), with no render per pointer move.
//
// Escape puts back what the drag started from. Every listener the drag adds goes when it ends: the
// pointer lets go, the browser cancels it, Escape, or `cancel` (the hat unmounting mid-drag).
import { type HatDrag, hatDragAt, hatDragEnd, HAT_DRAG_SLOP, type HatState } from "./hatRows";
import { dispatchHat, hatStateFor, setHatPulling, setHatState } from "./trayFoldMemory";

export type HatDragOptions = {
  chat: string | undefined;
  origin: HatDrag["origin"];
  /// One row's height and the most rows the hat takes: read once the press becomes a drag, then the
  /// most rows again on each move.
  measure: () => { rowHeight: number; maxRows: number };
  /// The rubber band's give past one row (px), on every pointer move while it gives; 0 when it ends.
  onBand?: (band: number) => void;
  /// The pointer let go after a drag: the band it gave (to spring back from) and where it landed.
  onRelease?: (band: number, state: HatState) => void;
  /// The press never moved: a click on what it was pressed on.
  onPress?: () => void;
  /// The press ended, however (let go, cancelled, Escape), after its listeners went.
  onEnd?: () => void;
};

/// Starts watching a press. Returns `cancel`, which ends it and puts back what it started from.
export function beginHatDrag(event: PointerEvent, options: HatDragOptions): () => void {
  const { chat, origin } = options;
  const view = event.view ?? window;
  const root = (event.target instanceof Node ? event.target.ownerDocument : document)?.documentElement;
  const start = hatStateFor(chat);
  const startY = event.clientY;
  const pointer = event.pointerId;
  let drag: HatDrag | undefined;
  let band = 0;
  let done = false;

  const finish = () => {
    if (done) return;
    done = true;
    view.removeEventListener("pointermove", move, true);
    view.removeEventListener("pointerup", up, true);
    view.removeEventListener("pointercancel", cancel, true);
    view.removeEventListener("keydown", key, true);
    root?.removeEventListener("lostpointercapture", lost);
    try {
      if (root?.hasPointerCapture(pointer)) root.releasePointerCapture(pointer);
    } catch {
      // The pointer is gone already.
    }
    if (origin === "pill") setHatPulling(undefined);
    options.onEnd?.();
  };
  const setBand = (next: number) => {
    if (next === band) return;
    band = next;
    options.onBand?.(next);
  };
  function move(moved: PointerEvent) {
    if (moved.pointerId !== pointer) return;
    const down = moved.clientY - startY;
    if (!drag) {
      if (Math.abs(down) < HAT_DRAG_SLOP) return;
      // From the pull tab only an upward drag is one: a press that slides down stays a click.
      if (origin === "pill" && down > 0) return;
      const { rowHeight, maxRows } = options.measure();
      drag = { origin, startRows: Math.max(0, start.view.kind === "hidden" ? 0 : start.view.rows), rowHeight, maxRows };
      try {
        root?.setPointerCapture(pointer);
        root?.addEventListener("lostpointercapture", lost);
      } catch {
        // No capture (a synthetic event): the window's listeners still see the drag.
      }
      if (origin === "pill") {
        setHatPulling(chat);
        // It comes back from nothing, a row at a time.
        dispatchHat(chat, { type: "drag", rows: 0 });
      }
    } else {
      // The most rows, again: a list that mounts as the hat opens, or lines that come and go, change it.
      drag = { ...drag, maxRows: options.measure().maxRows };
    }
    moved.preventDefault();
    const at = hatDragAt(drag, down);
    dispatchHat(chat, { type: "drag", rows: at.rows });
    setBand(at.band);
  }
  function up(ended: PointerEvent) {
    if (ended.pointerId !== pointer) return;
    if (!drag) {
      finish();
      options.onPress?.();
      return;
    }
    const rows = hatDragEnd(drag, ended.clientY - startY);
    const gave = band;
    // From the pull tab and let go before a row came back: as it was.
    const landed =
      origin === "pill" && rows === 0 ? (setHatState(chat, start), start) : dispatchHat(chat, { type: "drag", rows });
    band = 0;
    // Before the pull lets go: a hat it brought back under a look that tucks every hat untucks it
    // first (TrayPullTab.tsx), so no frame shows the tab again.
    try {
      options.onRelease?.(gave, landed);
    } finally {
      finish();
    }
  }
  function cancel(event?: Event) {
    if (event instanceof PointerEvent && event.pointerId !== pointer) return;
    if (done) return;
    if (drag) {
      setHatState(chat, start);
      setBand(0);
    }
    finish();
  }
  function lost(event: Event) {
    if ((event as PointerEvent).pointerId === pointer) cancel();
  }
  function key(pressed: KeyboardEvent) {
    if (pressed.key !== "Escape" || !drag) return;
    // The drag's Escape only: the composer's (stop the turn, close a menu) never sees it.
    pressed.preventDefault();
    pressed.stopPropagation();
    cancel();
  }
  view.addEventListener("pointermove", move, true);
  view.addEventListener("pointerup", up, true);
  view.addEventListener("pointercancel", cancel, true);
  view.addEventListener("keydown", key, true);
  return () => cancel();
}

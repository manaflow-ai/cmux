// The feel harness's trace: what a simulated cursor did and what the page painted, frame by frame
// (Leo, 2026-11-22: "these should be doable via automation. the "feel" and "vibes" thing. you can
// simulate cursors clicking around."). The probe (probe.ts) writes it in the page; the verdicts
// (verdicts.ts) read it in the test, with no browser, so each one is unit-tested on made-up traces.

/** A box in page px. */
export type Box = { x: number; y: number; w: number; h: number };

/** A live text's string and its drawn width (the text's own ink box, not its element's). */
export type TextSample = { text: string; width: number };

/** The pointer as the page last heard it before a frame was painted. */
export type PointerSample = { x: number; y: number; buttons: number };

/** One painted frame. */
export type FeelFrame = {
  /** The frame's time (requestAnimationFrame's, on performance.now's clock). */
  t: number;
  pointer: PointerSample | null;
  /** Each tracked element's drawn box, null while it is not in the page. */
  boxes: Record<string, Box | null>;
  /** Each tracked live text, null while it is not in the page. */
  texts: Record<string, TextSample | null>;
  /** Each tracked state (an attribute, a class, presence), as a string; null while absent. */
  states: Record<string, string | null>;
  /** Layout shift the browser scored since the frame before (Chromium; 0 elsewhere). */
  shift: number;
};

/** A pointer or click event the page heard, on the frames' clock. */
export type FeelEvent = { t: number; type: string; x: number; y: number; buttons: number; detail: number };

export type FeelTrace = { frames: FeelFrame[]; events: FeelEvent[] };

/** What the probe tracks, by name: CSS selectors (the first match). */
export type ProbeSpec = {
  boxes?: Record<string, string>;
  texts?: Record<string, string>;
  /** `selector` alone: "1" while it matches, else null. `attr`: that attribute's value.
   *  `attr: "class"` reads the class list. */
  states?: Record<string, { selector: string; attr?: string }>;
};

export type Edge = "top" | "bottom" | "left" | "right";

/** The coordinate of one edge of a box. */
export function edgeOf(box: Box, edge: Edge): number {
  switch (edge) {
    case "top":
      return box.y;
    case "bottom":
      return box.y + box.h;
    case "left":
      return box.x;
    case "right":
      return box.x + box.w;
  }
}

/** The pointer coordinate on the axis an edge moves along. */
export function pointerOn(pointer: PointerSample, edge: Edge): number {
  return edge === "top" || edge === "bottom" ? pointer.y : pointer.x;
}

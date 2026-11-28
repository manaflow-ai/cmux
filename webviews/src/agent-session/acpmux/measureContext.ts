import { prepare } from "@chenglou/pretext";

/// The canvas the text layout library measures words on, made fresh every MEASURES_PER_CANVAS
/// measures and whenever the library's caches start over.
///
/// The library measures on one 1x1 OffscreenCanvas it makes on its first measure and keeps for the
/// page's life. Blink keeps every text that canvas's context measured, on the context's font (a
/// `PlainTextNode` with its shape results per word, in the font's FrameShapeCache), and lets them go
/// only when the canvas draws a frame, which a canvas that only measures never does, or when the
/// context goes. So that cache grew with the chat: 14,196 nodes, 16.8 MB of the god chat's page
/// against the long chat's 1,377 and 1.6 MB (the transcript-replay bench's heap snapshot, native
/// memory the bench's JS heap row does not count). The library measures each new word once (its own
/// word cache, bounded by model.ts `notePreparedText`), so the count of measures is the count of
/// texts Blink holds: the library is given a context that measures on a real one, and that real one
/// is a new canvas after MEASURES_PER_CANVAS measures (or `freshMeasureContext`), so the old one and
/// every text it held go with it.
///
/// The library makes its canvas with `new OffscreenCanvas(1, 1).getContext("2d")` and uses only
/// `font` and `measureText` on it (pretext 0.0.9 dist/measurement.js).

type MeasureContext = Pick<OffscreenCanvasRenderingContext2D, "font" | "measureText">;

/// About 0.3 MB of Blink's measured texts at most (1.2 KB each in the god chat's snapshot). Every
/// open chat is a page with its own canvas, so this is paid once per chat: at 2,000 it was 2.5 MB of
/// FrameShapeCache and 1.8 MB of PlainTextNode a grown chat's page (chat-100k-flat grown_x5's heap
/// retainers), the most a grown page held over an empty one of any one place. Blink's copy saves no
/// work: the library measures each word once and keeps its widths, so a new canvas costs only itself.
export const MEASURES_PER_CANVAS = 250;

let real: MeasureContext | undefined;
let adopted = false;
let measures = 0;

function newContext(): MeasureContext | undefined {
  return new OffscreenCanvas(1, 1).getContext("2d") ?? undefined;
}

const delegate: MeasureContext = {
  get font() {
    return real?.font ?? "";
  },
  set font(font: string) {
    if (real) real.font = font;
  },
  measureText(text: string) {
    if (measures >= MEASURES_PER_CANVAS) freshMeasureContext();
    measures += 1;
    return real!.measureText(text);
  },
};

/// Has the library make its canvas now, as `delegate` (pure for the page otherwise: the global
/// `OffscreenCanvas` is the engine's again before this returns). Nothing when there is no
/// OffscreenCanvas (the library then measures on a DOM canvas of its own) or when the library
/// already made its canvas.
function adopt(): void {
  if (typeof OffscreenCanvas !== "function") return;
  const Engine = OffscreenCanvas;
  real = newContext();
  if (!real) return;
  let asked = false;
  const scope = globalThis as { OffscreenCanvas: unknown };
  scope.OffscreenCanvas = class {
    getContext() {
      asked = true;
      return delegate;
    }
  };
  try {
    prepare("x", "16px sans-serif");
  } catch {
    // The library's first measure failing leaves it without a canvas; it asks again next time.
  } finally {
    scope.OffscreenCanvas = Engine;
  }
  adopted = asked;
  if (!adopted) real = undefined;
}

let tried = false;

/// Gives the library `delegate` as its canvas before its first measure. Every `prepare` and
/// `prepareWithSegments` in the chat calls this first, so the swap waits for the first text the
/// chat lays out instead of running while the pane's modules evaluate, ahead of the handshake.
export function ensureMeasureContext(): void {
  if (tried) return;
  tried = true;
  adopt();
}

/// Puts the library's measures on a new canvas, so Blink lets go of every text the last one held.
/// The font carries over: the library sets it once per font, not before each measure. False when the
/// library measures on a canvas of its own.
export function freshMeasureContext(): boolean {
  if (!adopted || !real) return false;
  const font = real.font;
  const next = newContext();
  if (!next) return false;
  next.font = font;
  real = next;
  measures = 0;
  return true;
}

import { prepare } from "@chenglou/pretext";

/// The canvas the text layout library measures words on, made fresh when its caches start over.
///
/// The library measures on one 1x1 OffscreenCanvas it makes on its first measure and keeps for the
/// page's life. Blink keeps every text that canvas's context measured (a `PlainTextNode` with its
/// shape results per word) and lets them go only when the canvas draws a frame, which a canvas
/// that only measures never does, or when the context goes. So that cache grew with the chat:
/// 14,196 nodes, 16.8 MB of the god chat's heap against the long chat's 1,377 and 1.6 MB (the
/// transcript-replay bench's heap snapshot). The library's own word cache is already bounded
/// (model.ts `notePreparedText`); this bounds Blink's under it the same way: the library is given a
/// context that measures on a real one, and `freshMeasureContext` swaps that real one for a new
/// canvas, so the old one and every text it held go with it.
///
/// The library makes its canvas with `new OffscreenCanvas(1, 1).getContext("2d")` and uses only
/// `font` and `measureText` on it (pretext 0.0.9 dist/measurement.js).

type MeasureContext = Pick<OffscreenCanvasRenderingContext2D, "font" | "measureText">;

let real: MeasureContext | undefined;
let adopted = false;

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
adopt();

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
  return true;
}

// A chat's rail ticks draw after its first paint (ThreadMinimapView `ticksDrawn`), on `afterPaint`.
// The rails waiting for that frame are kept here, so a test can draw them without running a whole
// frame: a frame also runs the rail's other animation-frame work (measuring, fitting to the pane),
// which a jsdom pane of 0 px answers by hiding the rail.
import { afterPaint } from "../../../protocol/intents/schedule";

const waiting = new Set<() => void>();

/// Runs `draw` after the next paint, once. Returns a cancel function.
export function drawTicksAfterPaint(draw: () => void): () => void {
  let done = false;
  const run = () => {
    if (done) return;
    done = true;
    waiting.delete(run);
    draw();
  };
  waiting.add(run);
  const cancel = afterPaint(run);
  return () => {
    done = true;
    waiting.delete(run);
    cancel();
  };
}

/// Draws every rail's waiting ticks now, as their frame would.
export function drawWaitingTicksForTests(): void {
  for (const run of [...waiting]) run();
}

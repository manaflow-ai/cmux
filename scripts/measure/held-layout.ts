// Measures transcript layout bookkeeping while one committed placement holds its arrays.
// From webviews with dependencies installed: cmux-ci test -- bun ../scripts/measure/held-layout.ts
import { LayoutBuffers, type ConversationLayout } from "../../webviews/src/agent-session/acpmux/model";

function elapsed(estimates: number): number {
  const buffers = new LayoutBuffers();
  const held = { ...buffers.take(undefined, 0, 2), totalHeight: 0 };
  buffers.wrote(held);
  buffers.hold(held);
  let previous: ConversationLayout = held;
  const start = performance.now();
  for (let i = 0; i < estimates; i += 1) {
    const layout = { ...buffers.take(previous, 1, 2), totalHeight: 0 };
    layout.tops[1] = i;
    buffers.wrote(layout);
    previous = layout;
  }
  const ms = performance.now() - start;
  if (held.tops[1] !== 0 || previous.tops[1] !== estimates - 1) throw new Error("incorrect layout");
  return ms;
}

elapsed(1000);
for (const estimates of [4000, 16000]) {
  const samples = [elapsed(estimates), elapsed(estimates), elapsed(estimates)].sort((a, b) => a - b);
  console.log(`${estimates} estimates: ${samples[1]!.toFixed(1)} ms (median)`);
}

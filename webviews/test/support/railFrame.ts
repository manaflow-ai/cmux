import { act } from "react";
import { drawWaitingTicksForTests } from "../../src/agent-session/acpmux/threadMinimap/ticksFrame";

/// A chat's rail draws its ticks in the frame after the chat's first paint (ThreadMinimap.tsx
/// `ticksDrawn`, ticksFrame.ts): this draws them now, as that frame would before a person sees the
/// rail, so a test reads the ticks a chat shows. It runs no animation frame: the rail's other frame
/// work stays where each test drives it (thread-rail-ticks-after-paint.test.tsx runs the real frame).
/// A synchronous act: an async one yields to the host, and a jsdom frame due then runs as well.
/// The first flushes the effects of a commit still pending, which schedule the ticks.
export const railFrame = async () => {
  act(() => {});
  act(() => drawWaitingTicksForTests());
};

/// Awaits a render's act, then draws the rail's ticks (railFrame). React's act returns a thenable
/// whose `then` does not chain, so `act(...).then(railFrame)` resolves before the frame runs.
export const withRail = async (acted: PromiseLike<unknown>) => {
  await acted;
  await railFrame();
};

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

/// Runs `count` of the window's animation frames inside an act. A scroll moves the rail's band in
/// the frame after its event (ThreadMinimap.tsx, the band's `place`, bad28b3b), and the band's move
/// places the rail's list in the frame after that commit (the list's `place`, #50774 and #54847): a
/// test that scrolls and then reads the rail runs both, as a browser would before the rail is seen.
export const scrollFrames = async (win: { requestAnimationFrame: (callback: () => void) => number }, count = 2) => {
  for (let frame = 0; frame < count; frame++)
    await act(async () => {
      await new Promise<void>((resolve) => win.requestAnimationFrame(() => resolve()));
    });
};

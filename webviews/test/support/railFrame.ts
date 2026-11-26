import { act } from "react";

/// A chat's rail draws its ticks in the frame after the chat's first paint, and the task after it
/// (ThreadMinimap.tsx `ticksDrawn`, schedule.ts `afterPaint`): this runs that frame and that task, as
/// a browser would before a person sees the rail, so a test reads the ticks a chat shows.
export const railFrame = () =>
  act(async () => {
    await new Promise((resolve) => requestAnimationFrame(() => resolve(null)));
    for (let turn = 0; turn < 3; turn++) await new Promise((resolve) => setTimeout(resolve, 0));
  });

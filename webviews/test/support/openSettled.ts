// A chat that opens at its latest row draws only the rows in view in its first commit: the history
// above them mounts after that frame has painted (two frames, then a task: VirtualTranscript's
// `deferHistory`), and a cold open's rough estimate above the view is laid out whole after a frame
// and a task (`roughAbove`). A test whose premise is the transcript as it stands once opened (its
// history mounted, its heights laid out) waits for both before it measures.
import { act } from "react";

/// Waits out the open's deferred history mount and rough-estimate settle in `window`'s frames.
export async function openSettled(window: { requestAnimationFrame(callback: () => void): number }) {
  const frame = () => new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve()));
  const task = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
  await act(async () => {
    await frame();
    await frame();
    await task();
  });
  // The history's commit can place the view again (a frame and a task more for anything it set off).
  await act(async () => {
    await frame();
    await task();
  });
}

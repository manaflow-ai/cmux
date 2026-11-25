// How long a connection label is on screen during a scripted link timeline, on fake timers: the one
// harness behind the before/after numbers of the quiet-connect work (Leo, 2026-11-14: "i also want all
// our connectivity stuff to shut up and load faster/percievably load faster"). A timeline is the state
// the view is given at each moment (a connect that completes in 0.8 s, a reconnect that heals in 6 s,
// a drop that lasts 15 s); the harness steps the clock in `TICK_MS` slices and sums the slices in
// which `visible()` is true. Callers turn fake timers on (`jest.useFakeTimers()`) before calling.
import { jest } from "bun:test";
import { act } from "react";

export const TICK_MS = 50;

export type LinkStep = { at: number; apply(): Promise<void> | void };

/// The ms `visible()` held over `[0, endMs)`, applying each step when the clock reaches its `at`.
/// The line `label-exposure <name> <ms>` it prints is what the PR's table quotes.
export async function labelExposure(
  name: string,
  steps: readonly LinkStep[],
  endMs: number,
  visible: () => boolean,
): Promise<number> {
  const pending = [...steps].sort((a, b) => a.at - b.at);
  let shown = 0;
  for (let now = 0; now < endMs; now += TICK_MS) {
    while (pending.length > 0 && pending[0]!.at <= now) {
      const step = pending.shift()!;
      await act(async () => {
        await step.apply();
      });
    }
    if (visible()) shown += TICK_MS;
    await act(async () => void jest.advanceTimersByTime(TICK_MS));
  }
  console.log(`label-exposure ${name} ${shown}`);
  return shown;
}

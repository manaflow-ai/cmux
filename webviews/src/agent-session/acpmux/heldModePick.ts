// A New Tab permission pick made before the page's actions connect (Leo, 2026-11-07: "I can't
// click to adjust the bypass permissions button there in that new tab screen"). The pick belongs
// to the page, not to the chip that took it: a first send can unmount the chips (the New Tab page
// leaves for its chat, newtab/screenActions.ts) before the connect installs `chat.mode`, and the
// pick must still apply. The connect calls `flushHeldModePick` right after it installs the page's
// actions (App.tsx), whatever is mounted then. One pick is held at a time; a newer one replaces it.

type Held = { modeId: string; run(modeId: string): Promise<unknown>; settle(result: Promise<unknown>): void };

let held: Held | undefined;

/// Holds `modeId` until the page's actions connect; `run` applies it then (chat.new, then
/// chat.mode). The promise settles with that run, or as applied when a newer pick replaces it.
export function holdModePick(modeId: string, run: (modeId: string) => Promise<unknown>): Promise<unknown> {
  return new Promise((resolve, reject) => {
    held?.settle(Promise.resolve());
    held = { modeId, run, settle: (result) => void result.then(resolve, reject) };
  });
}

/// The connect installed the page's actions: the held pick, if any, runs now.
export function flushHeldModePick(): void {
  const pick = held;
  if (!pick) return;
  held = undefined;
  let result: Promise<unknown>;
  try {
    result = pick.run(pick.modeId);
  } catch (error) {
    result = Promise.reject(error);
  }
  pick.settle(result);
}

/// The mode a pick holds, for tests and the chip's face.
export function heldModePickForTest(): string | undefined {
  return held?.modeId;
}

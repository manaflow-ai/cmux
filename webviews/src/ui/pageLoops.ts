import { pageClocks } from "./pageClock";

export type PageLoops = { visibilityState: DocumentVisibilityState; parked: boolean; loops: number; hidden_loops: number; animations: unknown[]; clocks: ReturnType<typeof pageClocks> };

export function pageLoops(doc: Document = document): PageLoops {
  const animations = typeof doc.getAnimations === "function" ? doc.getAnimations({ subtree: true }) : [];
  const infinite = animations.filter((animation) => {
    const timing = animation.effect?.getComputedTiming?.();
    return timing && (timing.iterations === Infinity || timing.duration === Infinity) && animation.playState === "running";
  });
  const hidden = doc.visibilityState === "hidden";
  return { visibilityState: doc.visibilityState, parked: Boolean((globalThis as { __cmuxPageParked?: boolean }).__cmuxPageParked), loops: infinite.length, hidden_loops: hidden ? infinite.length : 0, animations: infinite.map((a) => ({ playState: a.playState, animationName: (a as Animation & { animationName?: string }).animationName })), clocks: pageClocks(doc) };
}

export function installPageLoops(doc: Document = document): void {
  const target = globalThis as typeof globalThis & { cmuxDebug?: { loops?: () => PageLoops } };
  target.cmuxDebug ??= {};
  target.cmuxDebug.loops = () => pageLoops(doc);
}

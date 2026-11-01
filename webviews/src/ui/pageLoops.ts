import { pageClocks } from "./pageClock";

export type PageLoops = {
  visibilityState: DocumentVisibilityState;
  parked: boolean;
  loops: number;
  hidden_loops: number;
  animations: {
    playState: AnimationPlayState;
    animationName?: string;
    target?: string;
    pseudoElement?: string | null;
  }[];
  clocks: ReturnType<typeof pageClocks>;
};

type DebugWindow = Window & {
  __cmuxPageParked?: boolean;
  cmuxDebug?: { loops?: () => PageLoops };
};

export function pageLoops(doc: Document = document): PageLoops {
  const animations = typeof doc.getAnimations === "function" ? doc.getAnimations() : [];
  const infinite = animations.filter((animation) => {
    const timing = animation.effect?.getComputedTiming?.();
    return (
      timing && (timing.iterations === Infinity || timing.duration === Infinity) && animation.playState === "running"
    );
  });
  const parked = (doc.defaultView as DebugWindow | null)?.__cmuxPageParked === true;
  const hidden = doc.visibilityState === "hidden";
  const clocks = pageClocks(doc);
  // Only registered clocks and running infinite animations are counted; this is not a
  // global interception of every timer in the page.
  const loops = infinite.length + clocks.running;
  return {
    visibilityState: doc.visibilityState,
    parked,
    loops,
    hidden_loops: hidden ? loops : 0,
    animations: infinite.map((animation) => {
      const effect = animation.effect as KeyframeEffect | null;
      const target = effect?.target;
      return {
        playState: animation.playState,
        animationName: (animation as CSSAnimation).animationName,
        target: target?.getAttribute("class") || target?.id || target?.tagName,
        pseudoElement: effect?.pseudoElement,
      };
    }),
    clocks,
  };
}

export function installPageLoops(doc: Document = document): void {
  const target = doc.defaultView as DebugWindow | null;
  if (!target) return;
  target.cmuxDebug ??= {};
  target.cmuxDebug.loops = () => pageLoops(doc);
}

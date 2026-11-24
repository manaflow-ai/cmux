// The runtime half of the layout-motion detector: in every build but Release, the page judges what moves
// against the contract (schemas/layout-motion/contract.json) while it runs, and records each undeclared move
// (its surface, how far, what was declared then) where a person's report can be matched to it: the flicker
// ring as `layout-undeclared`, and the console on a dev page. Leo, 2026-11-18: "the things that move we only
// expect at certain times".
//
// It costs nothing at rest: a DOM change, a resize, a scroll or a browser layout-shift entry arms a burst that
// samples the tracked boxes every frame until they hold still for `QUIET_FRAMES` (or `CAP_MS` pass), then
// judges the burst (motionJudge.ts) and disarms. A person's own acts declare their moves as they happen: a
// wheel or a scroll key is a user scroll, a window resize a resize, a press or a key opens what it targets
// (and a menu, and the composer's growth). Everything else must be declared by the code that moves it
// (`declareMove`).
import { MEDIA_SELECTOR, sampleBoxes } from "./boxSample";
import { declareMove, openDeclarations, type MotionEvent } from "./motionContract";
import { judgeMotion, type JudgeFrame, type UndeclaredMove } from "./motionJudge";

/** Frames the boxes must hold still before a burst ends. */
const QUIET_FRAMES = 10;
/** The longest burst: a page that never holds still is judged in slices. */
const CAP_MS = 3000;
/** How long a person's act declares its moves after it happens. */
const ACT_MS = 500;
/** Undeclared moves kept for `report()`. */
const KEEP = 50;

export type MotionAudit = { stop(): void; report(): UndeclaredMove[] };

export function startMotionAudit(win: Window, record: (move: UndeclaredMove) => void): MotionAudit {
  const doc = win.document;
  const kept: UndeclaredMove[] = [];
  let frames: JudgeFrame[] = [];
  let handle = 0;
  let started = 0;
  let quiet = 0;
  let stopped = false;
  const acts: (() => void)[] = [];

  const act = (event: MotionEvent, targets?: Element[]) => {
    const end = declareMove(
      { event, scope: targets ? "targets" : "all", ...(targets ? { targets } : {}), by: "person" },
      { ms: ACT_MS },
    );
    acts.push(end);
    if (acts.length > 32) acts.shift()?.();
  };

  const read = () => {
    const open = openDeclarations();
    const targets = open.flatMap((declaration) => declaration.targets ?? []);
    const samples = sampleBoxes(doc, targets, [...doc.querySelectorAll(MEDIA_SELECTOR)]);
    frames.push({
      samples,
      declared: open.map(({ key, event, scope, once, by }) => ({ key, event, scope, once, by })),
    });
  };

  const still = (a: JudgeFrame | undefined, b: JudgeFrame | undefined) => {
    if (!a || !b || a.samples.size !== b.samples.size) return false;
    for (const [id, sample] of b.samples) {
      const was = a.samples.get(id);
      if (!was) return false;
      if (
        Math.abs(was.box.x - sample.box.x) > 0.5 ||
        Math.abs(was.box.y - sample.box.y) > 0.5 ||
        Math.abs(was.box.width - sample.box.width) > 0.5 ||
        Math.abs(was.box.height - sample.box.height) > 0.5
      )
        return false;
    }
    return true;
  };

  // Each frame is read once it has drawn (after its layout and ResizeObserver passes): a read in the
  // frame callback itself saw a resized page's rows rewrapped but not yet placed, which no frame paints. A
  // resize that lands between the frame and its read shows that same unplaced state: the read waits a frame.
  const drawn = new MessageChannel();
  let drewAt = "";
  const viewportNow = () => `${win.innerWidth}x${win.innerHeight}`;
  const tick = () => {
    drewAt = viewportNow();
    handle = -1;
    drawn.port2.postMessage(0);
  };
  drawn.port1.onmessage = () => {
    handle = 0;
    if (stopped) return;
    if (viewportNow() !== drewAt) {
      handle = win.requestAnimationFrame(tick);
      return;
    }
    read();
    quiet = still(frames.at(-2), frames.at(-1)) ? quiet + 1 : 0;
    if (quiet >= QUIET_FRAMES || win.performance.now() - started > CAP_MS) {
      const verdict = judgeMotion(frames);
      for (const move of verdict.moves) {
        record(move);
        kept.push(move);
        if (kept.length > KEEP) kept.shift();
      }
      // The next burst starts from where this one ended: its last frames have rested.
      frames = frames.slice(-3);
      return;
    }
    handle = win.requestAnimationFrame(tick);
  };

  const arm = () => {
    if (stopped || handle || doc.visibilityState !== "visible") return;
    started = win.performance.now();
    quiet = 0;
    handle = win.requestAnimationFrame(tick);
  };

  const mutations = new MutationObserver(arm);
  mutations.observe(doc.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
  const onResize = () => {
    act("resize");
    arm();
  };
  const onScroll = () => {
    act("user-scroll");
    arm();
  };
  const onPress = (event: Event) => {
    const target = event.target instanceof Element ? event.target : undefined;
    if (target) act("expand", [target]);
    act("menu");
    act("composer-growth");
    arm();
  };
  const onVisible = () => {
    // A page that comes back may be laid out again at its new size: the frames before it hid say nothing.
    frames = [];
    arm();
  };
  win.addEventListener("resize", onResize);
  win.addEventListener("wheel", onScroll, { capture: true, passive: true });
  win.addEventListener("scroll", onScroll, { capture: true, passive: true });
  win.addEventListener("pointerdown", onPress, { capture: true, passive: true });
  win.addEventListener("keydown", onPress, { capture: true, passive: true });
  doc.addEventListener("visibilitychange", onVisible);
  let shifts: PerformanceObserver | undefined;
  try {
    if (
      typeof PerformanceObserver !== "undefined" &&
      PerformanceObserver.supportedEntryTypes?.includes("layout-shift")
    ) {
      const observer = new PerformanceObserver(arm);
      observer.observe({ type: "layout-shift", buffered: false });
      shifts = observer;
    }
  } catch {
    shifts = undefined;
  }
  // The page at rest as the audit starts; after that only frames that drew are read (a read inside a
  // resize or mutation sees its layout before the page placed it).
  read();
  arm();

  return {
    stop() {
      stopped = true;
      if (handle > 0) win.cancelAnimationFrame(handle);
      drawn.port1.close();
      mutations.disconnect();
      shifts?.disconnect();
      for (const end of acts) end();
      win.removeEventListener("resize", onResize);
      win.removeEventListener("wheel", onScroll, { capture: true });
      win.removeEventListener("scroll", onScroll, { capture: true });
      win.removeEventListener("pointerdown", onPress, { capture: true });
      win.removeEventListener("keydown", onPress, { capture: true });
      doc.removeEventListener("visibilitychange", onVisible);
    },
    report: () => [...kept],
  };
}

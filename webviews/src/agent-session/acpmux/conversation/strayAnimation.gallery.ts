// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// The turn's end fold when the reader is NOT looking at it. Leo, 2026-11-22 13:18Z: "there's also
// some situations where like your chat folds or whatever, i scroll down, some bullshit ABOVE
// folds...? and plays an animation!? so there's some bullshit animation where i dont expect it to
// be, which is horrendous. idk, something about like how and when animations play. edge cases at
// teh top area of teh screeen and a long turn/tool call/sterring situation that has a wide-ass
// aggressive fold..."
//
// Each variant is the same long chat whose last turn runs a wide run of tool calls and writes a
// long reply. The reader has scrolled DOWN into the reply, so the run that the turn's end folds
// sits above the view: entirely above it, straddling its top edge, or far above it. Then the turn
// ends. The fix (conversation/offscreenMotion.ts, turnEndFold.ts `captureTurnEnd` and
// `endOnReaderScroll`) makes that end apply at once, with no motion, and settles a fold in flight
// the moment the reader's own wheel arrives.
//
// `window.cmuxStrayAnimation` is the report each play leaves: the running animations at the end's
// first frames, split by whether their element is in the scroller's view, and the view's offset
// before and after. `?hold=1` on the frame URL stops the play right before the turn ends and leaves
// `window.cmuxStrayAnimation.end()` for a capture script to call frame by frame
// (scripts/gallery/stray-animation-capture.ts).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";

const ROW = "stray-anim-run";
const REPLY = "stray-anim-reply";

const paragraph = (index: number) =>
  `Note ${index}. The fetch helper retries every failure the same way, so a 404 waits through three ` +
  "backoffs before it fails. I read how the helper decides to retry and who calls it, then where the " +
  "backoff is set and which callers expect a client error to fail at once.";

/// Six finished turns above, so the scroller has room for the reader to be far from the top.
const head: AcpmuxRow[] = Array.from({ length: 6 }, (_, index) => {
  const minutes = 90 - index * 8;
  return [
    user(`Check part ${index + 1} of the retry loop`, minutes, { id: `stray-anim-user-${index}` }),
    assistant([paragraph(index * 2 + 1), paragraph(index * 2 + 2)].join("\n\n"), minutes - 1, {
      id: `stray-anim-assistant-${index}`,
    }),
    summary(minutes - 1, { id: `stray-anim-summary-${index}`, status: "completed", toolCount: 1 }),
  ];
}).flat();

const read = (id: string, path: string) =>
  tool(`Read ${path}`, "read", "completed", {
    id,
    output: Array.from({ length: 10 }, (_, line) => `${path}:${line + 1}  retry(${line}) // backoff`).join("\n"),
  });
const command = (id: string, line: string) =>
  tool(line, "execute", "completed", { id, command: line, output: `${line}: ok\n`, exitCode: 0 });

/// "a long turn/tool call/sterring situation that has a wide-ass aggressive fold": nine calls, which
/// the end folds into one closed line.
const work: AcpmuxActivity[] = [
  read("stray-anim-c1", "fetch.ts"),
  read("stray-anim-c2", "retry.ts"),
  read("stray-anim-c3", "backoff.ts"),
  command("stray-anim-c4", "bun test fetch"),
  read("stray-anim-c5", "client.ts"),
  read("stray-anim-c6", "errors.ts"),
  command("stray-anim-c7", "bun test retry"),
  read("stray-anim-c8", "cases.ts"),
  command("stray-anim-c9", "bun test backoff --all"),
];

/// The reply the agent writes under the run: tall enough that the reader can sit deep inside it with
/// the run well above the view.
const reply = (version: number) =>
  assistant(Array.from({ length: 10 }, (_, index) => paragraph(30 + index)).join("\n\n"), 4, {
    id: REPLY,
    version,
  });

const snapshot = (version: number, isWorking: boolean) =>
  chat(
    [
      ...head,
      user("Read the retry code and run every one of its checks", 6, { id: "stray-anim-user-last" }),
      activity(work, 5, { id: ROW, version }),
      reply(version),
      ...(isWorking ? [] : [summary(3.9, { id: "stray-anim-summary-last", status: "completed", toolCount: 9 })]),
    ],
    { title: "Retry loop", isWorking },
  );

type AnimationSeen = {
  /// Whether the animated element's box meets the scroller's view at all.
  inView: boolean;
  name: string;
  /// The element's top against the view's top: negative is above the view.
  top: number;
  height: number;
  target: string;
};

export type StrayAnimationReport = {
  /// Where the run the end folds sat against the view's top before the turn ended.
  runTopBeforeEnd: number;
  runBottomBeforeEnd: number;
  scrollBefore: number;
  scrollAfter: number;
  /// Running animations sampled on the frames right after the turn ended.
  frames: { ms: number; animations: AnimationSeen[] }[];
  /// The worst frame's count of running animations whose element is out of the view.
  offscreenAnimations: number;
  /// Whether the transcript was still folding a frame after the end.
  foldedAfterEnd: boolean;
  end?: () => void;
  sample?: () => AnimationSeen[];
};

declare global {
  interface Window {
    cmuxStrayAnimation?: StrayAnimationReport;
  }
}

const scroller = (doc: Document) => doc.querySelector<HTMLElement>(".acpmux-scroll")!;
const rowOf = (doc: Document, id: string) => doc.querySelector<HTMLElement>(`[data-row-id="${id}"]`);

/** Running animations now, each with its element's place against the scroller's view. */
function sampleAnimations(doc: Document): AnimationSeen[] {
  const view = scroller(doc).getBoundingClientRect();
  const seen: AnimationSeen[] = [];
  for (const animation of doc.getAnimations()) {
    if (animation.playState !== "running") continue;
    if (animation.effect?.getComputedTiming().endTime === Infinity) continue;
    const target = (animation.effect as KeyframeEffect | undefined)?.target;
    if (!(target instanceof Element)) continue;
    const box = target.getBoundingClientRect();
    seen.push({
      inView: box.bottom > view.top && box.top < view.bottom,
      name:
        (animation as unknown as { animationName?: string }).animationName ??
        (animation as unknown as { transitionProperty?: string }).transitionProperty ??
        "animation",
      top: Math.round(box.top - view.top),
      height: Math.round(box.height),
      target: `${target.tagName.toLowerCase()}.${String((target as HTMLElement).className).slice(0, 60)}`,
    });
  }
  return seen;
}

/** Waits until every finite animation ended and the offset and height held still for a few frames. */
const settle = async (ctx: Parameters<Play>[0], ready: () => boolean = () => true) => {
  let last = "";
  let still = 0;
  await ctx.waitFor(
    () => {
      if (!ready()) return false;
      const running = ctx.document
        .getAnimations()
        .some((each) => each.playState === "running" && each.effect?.getComputedTiming().endTime !== Infinity);
      const node = scroller(ctx.document);
      const now = `${node.scrollTop}:${node.scrollHeight}`;
      still = !running && now === last ? still + 1 : 0;
      last = now;
      return still >= 6;
    },
    { capMs: 10_000 },
  );
};

/** The reader's own wheel, then a scroll that puts `line` `at` px under the view's top. */
const bringTo = async (ctx: Parameters<Play>[0], line: HTMLElement, at: number) => {
  const node = scroller(ctx.document);
  node.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
  node.scrollTop += line.getBoundingClientRect().top - node.getBoundingClientRect().top - at;
  node.dispatchEvent(new Event("scroll"));
  await settle(ctx);
};

type Scene = {
  /// Where the run's TOP sits against the view's top once the reader has scrolled down: negative is
  /// above the view.
  runTop: number;
  /// The reader keeps wheeling while the fold is in flight (endOnReaderScroll).
  wheelDuringFold?: true;
};

/// The frames sampled after the turn ends: the fold's own motion is a few hundred ms.
const FRAMES_MS = [0, 16, 48, 96, 160, 240, 360];

function scene(which: Scene): Play {
  return async (ctx) => {
    const doc = ctx.document;
    const view = doc.defaultView!;
    await ctx.waitFor(() => scroller(doc) && rowOf(doc, ROW) && rowOf(doc, REPLY), { capMs: 10_000 });
    await settle(ctx);
    const run = rowOf(doc, ROW)!;
    // The reader scrolls down into the reply, leaving the run above the view.
    await bringTo(ctx, run, which.runTop);
    const node = scroller(doc);
    const box = () => run.getBoundingClientRect().top - node.getBoundingClientRect().top;
    const report: StrayAnimationReport = {
      runTopBeforeEnd: Math.round(box()),
      runBottomBeforeEnd: Math.round(run.getBoundingClientRect().bottom - node.getBoundingClientRect().top),
      scrollBefore: node.scrollTop,
      scrollAfter: node.scrollTop,
      frames: [],
      offscreenAnimations: 0,
      foldedAfterEnd: false,
    };
    report.sample = () => sampleAnimations(doc);
    const end = () => {
      view.cmuxAcpmuxBridge?.receive(structuredClone(snapshot(2, false)));
    };
    report.end = end;
    view.cmuxStrayAnimation = report;
    // `?hold=1`: a capture script ends the turn itself, so it can screenshot each frame.
    if (new URLSearchParams(view.location.search).get("hold") === "1") return;

    const started = view.performance.now();
    const declared = ctx.declare({ kind: "expand", reason: "the turn's end folds its work" });
    end();
    for (const at of FRAMES_MS) {
      await new Promise<void>((resolve) => {
        const tick = () => (view.performance.now() - started >= at ? resolve() : view.requestAnimationFrame(tick));
        view.requestAnimationFrame(tick);
      });
      const animations = sampleAnimations(doc);
      report.frames.push({ ms: Math.round(view.performance.now() - started), animations });
      report.offscreenAnimations = Math.max(
        report.offscreenAnimations,
        animations.filter((each) => !each.inView).length,
      );
      if (doc.querySelector(".acpmux-thread[data-turn-end-folding]")) report.foldedAfterEnd = true;
      // The reader keeps reading while the fold is in flight: his wheel must settle it.
      if (which.wheelDuringFold && at >= 16 && at <= 160) {
        node.dispatchEvent(new WheelEvent("wheel", { deltaY: 40, bubbles: true }));
        node.scrollTop += 40;
        node.dispatchEvent(new Event("scroll"));
      }
    }
    await settle(ctx, () => !doc.querySelector(".acpmux-thread[data-turn-end-folding]"));
    declared();
    report.scrollAfter = scroller(doc).scrollTop;
    view.cmuxStrayAnimation = report;
  };
}

export default agentPaneEntry({
  id: "agent-pane.stray-animation",
  title: "A turn's end folds work the reader is not looking at",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/conversation/offscreenMotion.ts",
    "agent-session/acpmux/conversation/turnEndFold.ts#captureTurnEnd",
    "agent-session/acpmux/conversation/turnEndFold.ts#playTurnEnd",
  ],
  variants: {
    "work-above-view": {
      note: "Play: the reader has scrolled down into the reply and the run that the end folds sits just above the view's top. The turn ends: nothing in view may move, and no animation may run above the view.",
      snapshot: snapshot(1, true),
      play: scene({ runTop: -420 }),
    },
    "work-at-top-edge": {
      note: 'Play: the same end with the run straddling the view\'s top edge (Leo: "edge cases at teh top area of teh screeen"). The part in view may fold; nothing above the edge animates.',
      snapshot: snapshot(1, true),
      play: scene({ runTop: -120 }),
    },
    "work-far-above": {
      note: "Play: the run is a whole viewport above the view, out of the virtualizer's overscan. The end applies at once with no motion at all.",
      snapshot: snapshot(1, true),
      play: scene({ runTop: -900 }),
    },
    "reader-scrolling": {
      note: "Play: the run is above the view and the reader keeps wheeling while the fold is in flight. His own wheel settles the fold; the fold's passes never turn his scroll into motion.",
      snapshot: snapshot(1, true),
      play: scene({ runTop: -420, wheelDuringFold: true }),
    },
  },
});

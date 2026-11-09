import { Plugin, PluginKey, type Transaction } from "@milkdown/kit/prose/state";
import { ReplaceStep } from "@milkdown/kit/prose/transform";
import type { EditorView } from "@milkdown/kit/prose/view";
import { FIELD_GROWTH_EVENT, type FieldGrowthDetail } from "./fieldGrowthEvent";
import { experimentArm } from "../../../experiments/experiment";
import { SETTLING_SCROLLER_ATTRIBUTE } from "../../../scrollers";
import { MOTION_SPRINGS, springCurve, type SpringParameters } from "../../../files-panel-motion";
import { MOTION_EASE_OUT, MOTION_MS } from "../../../motion/scale.generated";
import { motionMode } from "../../../ui/motion/motionMode";
import { fieldGrowthMotion, type FieldGrowthArm } from "./fieldGrowth.experiment";
import { sliceHoldsInline } from "./inlineNode";

// The prompt field's height moves to its text's on one motion, not in a step per line (Leo,
// 2026-11-07: "it's like the composer kind of doesn't grow smoothly. It grows in bursts."). The
// field lays out at its natural height (markdownField.css: auto, up to its cap); when an edit
// changes that height, this draws the field from the height it showed to the new one on the move
// spring (fieldGrowth.experiment.ts arms). It starts in the edit's own task, before the frame's
// layout and observers, so the first frame still draws the old height, and tells the transcript
// (fieldGrowthEvent.ts): it takes the end height into its room in one render and moves its rows
// home on the same curve and clock, on the compositor, with no render per frame.
//
// Where the text rides: a line typed or wrapped keeps the text's top on the field's moving top edge,
// so the lines already there move with the edge and the new line comes in at the bottom as the edge
// rises (no line moves faster than the edge, motion.md target 3). A growth of more than a line (a
// paste, dictation pasted in) or one that reaches the field's cap keeps the caret in view on every
// frame instead (caretInView.ts), the paste's end staying put at the bottom as the top edge rises.
//
// A move to a height the text fits draws no scrollbar thumb (scrollers.ts SETTLING_SCROLLER_ATTRIBUTE):
// mid-move the text is taller than the field, which would show the always-on composer thumb for the
// motion's length although nothing is left to scroll once it lands (Leo 2026-11-08: "stop showing a
// flash of the thumb scrollbar"). A move to the field's cap keeps its thumb: the text overflows.
//
// An edit that places an attachment (a paste, a drop, the + menu) changes the height in its frame:
// its tile shows at its final slot from its first frame, and the lines already there keep their
// place under the composer's top (composer-attach-no-jump.test.ts, Leo's #38155). Riding the moving
// edge drew the new tile a line low and slid it up over the spring.
//
// An edit that lands while the field moves retargets from the height drawn, keeping the motion's
// end. A value set from outside (a send clearing the prompt, a chat's draft), Reduce Motion and
// motion off change the height in the frame, as before. Nothing runs at rest: the animation and the
// text's observer exist only while the field moves, and both go when it lands or the editor goes.

/** The spring arms' springs; `ease` and `instant` have none. */
const SPRINGS: Partial<Record<FieldGrowthArm, SpringParameters>> = {
  spring: MOTION_SPRINGS.move,
  soft: { response: 0.24, dampingFraction: 1 },
};

/** A growth past this many lines keeps the caret in view rather than the text's top. */
const REVEAL_LINES = 1.5;

type Motion = {
  /** The running animation; replaced, at the same time on the same curve, when an edit keeps its end. */
  animation: Animation;
  keyframes: Keyframe[];
  timing: KeyframeAnimationOptions;
  /** The height it lands on (px). */
  to: number;
  /** When it lands (performance.now). */
  end: number;
  /** The caret stays in view on each frame (caretInView); else the text keeps its top. */
  reveal: boolean;
  /** The text's own size changes while it moves (a rewrap): retarget. */
  observer: ResizeObserver | undefined;
};

/** Whether a transaction placed an attachment's node: its steps' own slices, O(the edit). */
const placesAttachment = (tr: Transaction) =>
  tr.steps.some((step) => step instanceof ReplaceStep && sliceHoldsInline(step.slice));

/** Set on the state an attachment was placed in, until the next edit. */
const placedKey = new PluginKey<boolean>("fieldGrowthPlaced");

/** The motion running on each field (`.acpmux-md-field`), read by caretInView. */
const moving = new WeakMap<HTMLElement, Motion>();

/** Whether `scroller`'s growth keeps its text's top on the moving edge now: the caret's own reveal
 *  waits for it to land (it would scroll the lines up a line at once). */
export function growthHoldsTop(scroller: HTMLElement): boolean {
  const motion = moving.get(scroller);
  return motion !== undefined && !motion.reveal;
}

/** Keyframes and timing of a move from `from` to `to` px on `arm`, over at most `remaining` ms. */
function growthFrames(arm: FieldGrowthArm, from: number, to: number, remaining?: number) {
  const spring = SPRINGS[arm];
  if (spring) {
    // The spring sampled as height keyframes (linearly interpolated), so every engine runs it the
    // same, with no `linear()` easing (WebKit before Safari 17.2 has none).
    const { durationMs, progress } = springCurve(spring);
    return {
      progress,
      keyframes: progress.map((value) => ({ height: `${from + (to - from) * value}px` })),
      duration: remaining === undefined ? durationMs : Math.max(remaining, MOTION_MS.quick),
      easing: "linear",
    };
  }
  return {
    keyframes: [{ height: `${from}px` }, { height: `${to}px` }],
    duration: remaining === undefined ? MOTION_MS.standard : Math.max(remaining, MOTION_MS.quick),
    easing: MOTION_EASE_OUT,
  };
}

/** The plugin. `external` is true while the field applies a value set from outside it. */
export function fieldGrowth(external: () => boolean): Plugin {
  return new Plugin({
    key: placedKey,
    state: {
      init: () => false,
      apply: (tr) => tr.docChanged && placesAttachment(tr),
    },
    view(view: EditorView) {
      // The arm is read once per editor.
      const arm = experimentArm(fieldGrowthMotion);
      let scroller: HTMLElement | null = null;
      // The height the field last drew at rest, kept as it changes for any reason (a rewrap, the
      // window's cap) by the field's own observer, which delivers after the edit that changes it.
      let shown = -1;
      let restObserver: ResizeObserver | undefined;
      const attach = () => {
        scroller = view.dom.closest<HTMLElement>(".acpmux-md-field");
        if (!scroller || typeof ResizeObserver !== "function") return;
        shown = scroller.getBoundingClientRect().height;
        const field = scroller;
        restObserver = new ResizeObserver(() => {
          if (!moving.has(field)) shown = field.getBoundingClientRect().height;
        });
        restObserver.observe(field);
      };
      const land = (field: HTMLElement) => {
        const motion = moving.get(field);
        if (!motion) return;
        moving.delete(field);
        field.removeAttribute(SETTLING_SCROLLER_ATTRIBUTE);
        motion.observer?.disconnect();
        motion.animation.cancel();
      };
      /** Runs `motion` as `animation`, and lets the field rest when it ends. */
      const run = (field: HTMLElement, motion: Motion, animation: Animation) => {
        motion.animation = animation;
        const done = () => {
          if (moving.get(field) !== motion || motion.animation !== animation) return;
          moving.delete(field);
          field.removeAttribute(SETTLING_SCROLLER_ATTRIBUTE);
          motion.observer?.disconnect();
        };
        animation.addEventListener("finish", done, { once: true });
        animation.addEventListener("cancel", done, { once: true });
      };
      // perf-hot: one layout read per edit (ProseMirror's own caret reveal reads the same layout next).
      const follow = (atOnce = false) => {
        const field = scroller;
        if (!field) return;
        const running = moving.get(field);
        // Where the field is drawn now: mid-motion, the motion's height this frame.
        const from = running ? field.getBoundingClientRect().height : shown;
        // Its natural height, with no motion on it. Taller for that read, the field would clamp its
        // scroll to the taller box's end: the scroll it draws with is kept.
        const started = running?.animation.startTime ?? null;
        const scrolled = field.scrollTop;
        running?.animation.cancel();
        const to = field.getBoundingClientRect().height;
        shown = to;
        if (running && !atOnce && Math.abs(to - running.to) < 0.5) {
          // The same end (a second edit on the same line, the text's observer's first call): the
          // motion goes on where it was, on the same curve and clock. A started animation given its
          // start time runs from the next frame; left pending it would hold a frame still.
          const again = field.animate(running.keyframes, running.timing);
          if (started !== null) again.startTime = started;
          field.scrollTop = scrolled;
          run(field, running, again);
          return;
        }
        if (running) land(field);
        if (from < 0 || Math.abs(to - from) < 0.5) return;
        if (atOnce || arm === "instant" || external() || motionMode(field.ownerDocument) !== "full") return;
        const lineHeight = Number.parseFloat(getComputedStyle(field).lineHeight) || 20;
        const capped = field.scrollHeight > field.clientHeight + 1;
        const reveal = capped || Math.abs(to - from) > lineHeight * REVEAL_LINES || (running?.reveal ?? false);
        const now = performance.now();
        const { keyframes, duration, easing, progress } = growthFrames(
          arm,
          from,
          to,
          running ? running.end - now : undefined,
        );
        const timing = { duration, easing };
        const animation = field.animate(keyframes, timing);
        // Started now on the document's clock, not left pending: WebKit holds a pending animation a
        // few frames, which the rows' move (VirtualTranscript) would run ahead of. A retarget moves
        // on in the next frame from where the field is drawn.
        const timeline = field.ownerDocument.timeline?.currentTime;
        if (typeof timeline === "number") animation.startTime = timeline;
        if (running) field.scrollTop = scrolled;
        // The text rewrapped meanwhile (the actions beside it changed width): move to its height. Its
        // first call is the observation starting, with nothing changed.
        let observed = false;
        const observer =
          typeof ResizeObserver === "function"
            ? new ResizeObserver(() => {
                if (!observed) {
                  observed = true;
                  return;
                }
                if (moving.get(field) === motion) follow();
              })
            : undefined;
        const motion: Motion = { animation, keyframes, timing, to, end: now + duration, reveal, observer };
        moving.set(field, motion);
        // Read at the end height above: the text fits the field it lands on, so no thumb meanwhile.
        field.toggleAttribute(SETTLING_SCROLLER_ATTRIBUTE, !capped);
        run(field, motion, animation);
        observer?.observe(view.dom);
        // The transcript takes the end height into its room now and moves its rows on this curve.
        const detail: FieldGrowthDetail = { to, easing, duration, animation, ...(progress ? { progress } : {}) };
        field.dispatchEvent(new CustomEvent(FIELD_GROWTH_EVENT, { bubbles: true, detail }));
      };
      attach();
      return {
        update(next, previous) {
          if (!scroller) attach();
          if (!next.state.doc.eq(previous.doc)) follow(placedKey.getState(next.state) === true);
        },
        destroy() {
          restObserver?.disconnect();
          if (scroller) land(scroller);
        },
      };
    },
    props: {
      // ProseMirror's reveal after the edit, against the height the field still draws: while the
      // text keeps its top, the caret's line comes into view with the edge instead.
      handleScrollToSelection(view) {
        const field = view.dom.closest<HTMLElement>(".acpmux-md-field");
        return field ? growthHoldsTop(field) : false;
      },
    },
  });
}

import { Plugin } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";
import { FIELD_GROWTH_EVENT, type FieldGrowthDetail } from "./fieldGrowthEvent";
import { experimentArm } from "../../../experiments/experiment";
import { SETTLING_SCROLLER_ATTRIBUTE } from "../../../scrollers";
import { MOTION_SPRINGS, springCurve, type SpringParameters } from "../../../files-panel-motion";
import { MOTION_EASE_OUT, MOTION_MS } from "../../../motion/scale.generated";
import { motionMode } from "../../../ui/motion/motionMode";
import { fieldGrowthMotion, type FieldGrowthArm } from "./fieldGrowth.experiment";

// The prompt field's height moves to its text's on one motion, not in a step per line (Leo,
// 2026-11-07: "it's like the composer kind of doesn't grow smoothly. It grows in bursts."). The
// field lays out at its natural height (markdownField.css: auto, up to its cap); when an edit
// changes that height, this draws the field from the height it showed to the new one on the move
// spring (fieldGrowth.experiment.ts arms). It starts in the edit's own task, before the frame's
// layout and observers, so the first frame still draws the old height, and tells the transcript
// (fieldGrowthEvent.ts): it takes the end height into its room in one render and moves its rows
// home on the same curve and clock, on the compositor, with no render per frame.
//
// Where the text rides: on the field's bottom edge, which never moves (the dock grows upward from it,
// and the controls stand on it: composerLocation.css). Every line, the caret's and each attachment's
// tile is drawn at its final place on the screen from the move's first frame, and only the top edge
// glides, uncovering the top line as it rises or covering it as it falls (Leo 2026-11-22: "the caret
// gets fucking shot down past the composer as it goes" and "deleting attachments make the composer
// AND the fucking text jump in a layout shift instead of a smooth motion"). A growth holds the text's
// end on the bottom edge by its scroll (`holdBottom`). Its top used to ride the moving top edge
// instead: the new line, and the caret on it, came in below the field's bottom for the spring's
// length (11 px out for two frames in Chromium, composer-caret-frames.browser.test.ts). A shrink
// rides the top edge: what is left of the text sits above what went (a deleted line, a removed
// attachment), so it moves with the top edge on the spring, and the field never shows less than
// its text meanwhile. Padding the shrink's top to hold the bottom edge instead drew all of the
// text that is left one removed height down in the first frame (25 px for an attachment,
// composer-geometry-stable.test.ts).
// A growth that reaches the field's cap keeps the caret in view on every frame (caretInView.ts).
//
// A field whose top edge stays put instead (New Tab's, which grows downward from a fixed top:
// `--acpmux-field-grows: down` in newtab/screen.css) holds its text on that top edge (`holdTop`), so
// its text never moves on the screen either.
//
// A move to a height the text fits draws no scrollbar thumb (scrollers.ts SETTLING_SCROLLER_ATTRIBUTE):
// mid-move the text is taller than the field, which would show the always-on composer thumb for the
// motion's length although nothing is left to scroll once it lands (Leo 2026-11-08: "stop showing a
// flash of the thumb scrollbar"). A move to the field's cap keeps its thumb: the text overflows.
//
// An edit that places or removes an attachment moves on the same spring (composer-attach-no-jump.test.ts,
// Leo's #38155). Open: a tile whose image decodes after the paste still grows the field in one frame
// (composer-geometry-stable.test.ts, attachment add); following the text's resize at rest regressed
// composer-attach-no-jump and composer-shell-alignment, so the fix is the tile's final size at insert.
//
// An edit that lands while the field moves retargets from the height drawn, keeping the motion's
// end. A value set from outside (a send clearing the prompt, a chat's draft), Reduce Motion and
// motion off change the height in the frame, as before; motion turned off mid-growth lands it at once.
// Nothing runs at rest: the animation, the text's observer and the motion gate's watch exist only
// while the field moves, and all go when it lands or the editor goes.

/** The spring arms' springs; `ease` and `instant` have none. */
const SPRINGS: Partial<Record<FieldGrowthArm, SpringParameters>> = {
  spring: MOTION_SPRINGS.move,
  soft: { response: 0.24, dampingFraction: 1 },
};

type Motion = {
  /** The running animation; replaced, at the same time on the same curve, when an edit keeps its end. */
  animation: Animation;
  keyframes: Keyframe[];
  timing: KeyframeAnimationOptions;
  /** The height it lands on (px). */
  to: number;
  /** When it lands (performance.now). */
  end: number;
  /** The caret stays in view on each frame (caretInView); else the text keeps its end on the bottom edge. */
  reveal: boolean;
  /** The text holds the field's top edge (a shrink, New Tab's growth), else its bottom. */
  holdsTop: boolean;
  /** The text's own size changes while it moves (a rewrap): retarget. */
  observer: ResizeObserver | undefined;
  /** Stops watching the motion gate (`watchMotionGate`). */
  unwatch: () => void;
  /** Stops holding the text on its edge (`holdBottom`, `holdTop`); nothing for a reveal. */
  release: () => void;
};

/** While a growth holds the text's end on the field's bottom edge, keeps the field scrolled to its
 *  end. As the field grows the engine clamps its scroll by as much, so the text's end stays put; the
 *  engine's own caret reveal at each key typed while the field still moves (ProseMirror's
 *  handleScrollToSelection is held off, the engine's is not) cannot scroll it elsewhere: a scroll
 *  event runs in the frame's steps before paint, so the reset lands in the frame it would have
 *  drawn. Mid-move the text fits the height it lands on, so the person's own scroll has nowhere to
 *  go. */
function holdBottom(field: HTMLElement): () => void {
  const hold = () => {
    const end = field.scrollHeight - field.clientHeight;
    if (Math.abs(field.scrollTop - end) > 0.5) field.scrollTop = end;
  };
  hold();
  field.addEventListener("scroll", hold, { passive: true });
  return () => field.removeEventListener("scroll", hold);
}

/** While a growth on a field that grows downward holds its text on the fixed top edge, keeps the
 *  field scrolled to its top (the engine's caret reveal in the shorter box would scroll it). */
function holdTop(field: HTMLElement): () => void {
  const hold = () => {
    if (field.scrollTop !== 0) field.scrollTop = 0;
  };
  hold();
  field.addEventListener("scroll", hold, { passive: true });
  return () => field.removeEventListener("scroll", hold);
}

/** Calls `still` when the motion gate of `field`'s page leaves full motion while a growth runs: the
 *  app's switch (`data-cmux-motion`), the pane's (`data-agent-motion`, its zero tokens on the root's
 *  style) and Reduce Motion (ui/motion/motionMode.ts). Only while the field moves. */
function watchMotionGate(field: HTMLElement, still: () => void): () => void {
  const doc = field.ownerDocument;
  const check = () => {
    if (motionMode(doc) !== "full") still();
  };
  const observer = typeof MutationObserver === "function" ? new MutationObserver(check) : undefined;
  observer?.observe(doc.documentElement, {
    attributes: true,
    attributeFilter: ["data-cmux-motion", "data-agent-motion", "style"],
  });
  const media = doc.defaultView?.matchMedia?.("(prefers-reduced-motion: reduce)");
  media?.addEventListener?.("change", check);
  return () => {
    observer?.disconnect();
    media?.removeEventListener?.("change", check);
  };
}

/** The motion running on each field (`.acpmux-md-field`), read by caretInView. */
const moving = new WeakMap<HTMLElement, Motion>();

/** Whether `scroller`'s move holds its text on the bottom edge now: the caret's own reveal waits for
 *  it to land (the text is already where it lands). */
export function growthHoldsText(scroller: HTMLElement): boolean {
  const motion = moving.get(scroller);
  return motion !== undefined && !motion.reveal;
}

/** Keyframes and timing of a move from `from` to `to` px on `arm`, over at most `remaining` ms. */
function growthFrames(arm: FieldGrowthArm, from: number, to: number, remaining?: number) {
  const frame = (height: number): Keyframe => ({ height: `${height}px` });
  const spring = SPRINGS[arm];
  if (spring) {
    // The spring sampled as height keyframes (linearly interpolated), so every engine runs it the
    // same, with no `linear()` easing (WebKit before Safari 17.2 has none).
    const { durationMs, progress } = springCurve(spring);
    return {
      progress,
      keyframes: progress.map((value) => frame(from + (to - from) * value)),
      duration: remaining === undefined ? durationMs : Math.max(remaining, MOTION_MS.quick),
      easing: "linear",
    };
  }
  return {
    keyframes: [frame(from), frame(to)],
    duration: remaining === undefined ? MOTION_MS.standard : Math.max(remaining, MOTION_MS.quick),
    easing: MOTION_EASE_OUT,
  };
}

/** The plugin. `external` is true while the field applies a value set from outside it. */
export function fieldGrowth(external: () => boolean): Plugin {
  return new Plugin({
    view(view: EditorView) {
      // The arm is read once per editor.
      const arm = experimentArm(fieldGrowthMotion);
      let scroller: HTMLElement | null = null;
      // The height the field last drew at rest, kept as it changes for any reason (a rewrap, the
      // window's cap) by the field's own observer, which delivers after the edit that changes it.
      let shown = -1;
      let restObserver: ResizeObserver | undefined;
      // The field's fixed edge, read once: the bottom (the dock grows upward) unless its CSS says
      // it grows downward from a fixed top (New Tab).
      let growsDown = false;
      const attach = () => {
        scroller = view.dom.closest<HTMLElement>(".acpmux-md-field");
        if (!scroller || typeof ResizeObserver !== "function") return;
        growsDown = getComputedStyle(scroller).getPropertyValue("--acpmux-field-grows").trim() === "down";
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
        motion.unwatch();
        motion.release();
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
          motion.unwatch();
          motion.release();
        };
        animation.addEventListener("finish", done, { once: true });
        animation.addEventListener("cancel", done, { once: true });
      };
      // perf-hot: one layout read per edit (ProseMirror's own caret reveal reads the same layout next).
      const follow = () => {
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
        // Read before the same-end path: an edit after motion went off (or a value set from outside)
        // lands a running growth instead of playing it on.
        const moves = arm !== "instant" && !external() && motionMode(field.ownerDocument) === "full";
        if (running && moves && Math.abs(to - running.to) < 0.5) {
          // The same end (a second edit on the same line, the text's observer's first call): the
          // motion goes on where it was, on the same curve and clock. A started animation given its
          // start time runs from the next frame; left pending it would hold a frame still.
          const again = field.animate(running.keyframes, running.timing);
          if (started !== null) again.startTime = started;
          // A reveal keeps the scroll it drew with; a growth that holds the text's end keeps it at the
          // end (`holdBottom` runs on the scroll this sets); a shrink or a downward growth, its top.
          field.scrollTop = running.reveal ? scrolled : running.holdsTop ? 0 : field.scrollHeight - field.clientHeight;
          run(field, running, again);
          return;
        }
        if (running) land(field);
        if (from < 0 || Math.abs(to - from) < 0.5) return;
        if (!moves) return;
        const capped = field.scrollHeight > field.clientHeight + 1;
        // The rects include the composer's density zoom; line height and keyframes are in its CSS pixels. Unscaled, a
        // zoomed composer (every density but Default) animated toward the wrong height and jumped at the end.
        const cssHeight = Number.parseFloat(getComputedStyle(field).height);
        const scale = cssHeight > 0 ? to / cssHeight : 1;
        const reveal = capped || (running?.reveal ?? false);
        const holdsTop = growsDown || to < from;
        const now = performance.now();
        const { keyframes, duration, easing, progress } = growthFrames(
          arm,
          from / scale,
          to / scale,
          running ? running.end - now : undefined,
        );
        const timing = { duration, easing };
        const animation = field.animate(keyframes, timing);
        // Started now on the document's clock, not left pending: WebKit holds a pending animation a
        // few frames, which the rows' move (VirtualTranscript) would run ahead of. A retarget moves
        // on in the next frame from where the field is drawn.
        const timeline = field.ownerDocument.timeline?.currentTime;
        if (typeof timeline === "number") animation.startTime = timeline;
        if (running && reveal) field.scrollTop = scrolled;
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
        const motion: Motion = {
          animation,
          keyframes,
          timing,
          to,
          end: now + duration,
          reveal,
          holdsTop,
          observer,
          unwatch: watchMotionGate(field, () => land(field)),
          // The text fits the height it lands on: a growth holds its end on the bottom edge by the scroll,
          // which reaches 0 as the field lands; a shrink (and New Tab's growth) holds it on the top.
          release: reveal ? () => {} : holdsTop ? holdTop(field) : holdBottom(field),
        };
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
          if (!next.state.doc.eq(previous.doc)) follow();
        },
        destroy() {
          restObserver?.disconnect();
          if (scroller) land(scroller);
        },
      };
    },
    props: {
      // ProseMirror's reveal after the edit, against the height the field still draws: while the
      // text rides the bottom edge it is already where it lands, the caret's line with it.
      handleScrollToSelection(view) {
        const field = view.dom.closest<HTMLElement>(".acpmux-md-field");
        return field ? growthHoldsText(field) : false;
      },
    },
  });
}

import { Plugin, PluginKey, type Transaction } from "@milkdown/kit/prose/state";
import { ReplaceStep } from "@milkdown/kit/prose/transform";
import type { EditorView } from "@milkdown/kit/prose/view";
import { FIELD_GROWTH_EVENT, type FieldGrowthDetail } from "./fieldGrowthEvent";
import { experimentArm } from "../../../experiments/experiment";
import { SETTLING_SCROLLER_ATTRIBUTE } from "../../../scrollers";
import { cssTimeMs } from "../conversation/fold";
import { motionMode } from "../../../ui/motion/motionMode";
import { fieldGrowthMotion } from "./fieldGrowth.experiment";
import { sliceHoldsInline } from "./inlineNode";

// The prompt field's height moves to its text's on one motion, not in a step per line (Leo,
// 2026-11-07: "it's like the composer kind of doesn't grow smoothly. It grows in bursts."). The
// motion is a CSS height transition on the motion tokens (markdownField.css `[data-field-growth]`),
// not a spring sampled into Web Animation keyframes (Leo, 2026-11-11: "oof yeah there's some ultra
// shitty looking slow animations when the composer goes up"): it runs on the one spring, at its end
// by about 130 ms, turns from the height drawn when an edit retargets it, and the motion gate and
// Reduce Motion reach it through CSS.
//
// How it starts. An edit's own task (before the frame's layout and observers) reads the field's
// natural height once, as ProseMirror's own caret reveal reads the same layout next: at rest the
// field is `auto`; mid-motion the field's text is measured instead (the field keeps its moving
// height). The field is then given the height it drew, its style flushed (no layout), and the end
// height with the transition's attribute: the first frame still draws the old height. When it lands
// the inline height goes and the field rests at `auto` again (so a short pane can still take height
// from it, bottomStack.css).
//
// The transcript moves with it (fieldGrowthEvent.ts): it takes the end height into its room in one
// render and moves its rows home on the transition's own duration and curve, on the compositor.
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
// place under the composer's top (composer-attach-no-jump.test.ts, Leo's #38155).
//
// An edit that lands while the field moves sets the new end, and the transition turns from the
// height drawn. A value set from outside (a send clearing the prompt, a chat's draft), Reduce Motion,
// motion off and the `instant` arm change the height in the frame. Nothing runs at rest: no inline
// height, no transition (the attribute that carries it is only on a moving field).

/** The attribute that carries the field's height transition, valued with its arm. */
const GROWTH_ATTRIBUTE = "data-field-growth";

/** A growth past this many lines keeps the caret in view rather than the text's top. */
const REVEAL_LINES = 1.5;

type Motion = {
  /** The running transition. */
  animation: Animation;
  /** The height it lands on (px). */
  to: number;
  /** The caret stays in view on each frame (caretInView); else the text keeps its top. */
  reveal: boolean;
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

/** A computed length in px, or `fallback` for `none`, `auto` or a percentage left unresolved. */
const px = (value: string, fallback: number) => {
  const parsed = Number.parseFloat(value);
  return value.endsWith("px") && Number.isFinite(parsed) ? parsed : fallback;
};

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
      /** The field rests at its natural height again: no inline height, no transition. */
      const land = (field: HTMLElement) => {
        moving.delete(field);
        field.removeAttribute(SETTLING_SCROLLER_ATTRIBUTE);
        field.removeAttribute(GROWTH_ATTRIBUTE);
        field.style.removeProperty("height");
      };
      // perf-hot: one layout read per edit (ProseMirror's own caret reveal reads the same layout next).
      const follow = (atOnce = false) => {
        const field = scroller;
        if (!field) return;
        const running = moving.get(field);
        if (atOnce || arm === "instant" || external() || (!running && shown < 0)) {
          if (running) land(field);
          return;
        }
        const style = getComputedStyle(field);
        let to: number;
        let capped: boolean;
        if (running) {
          // Mid-motion the field keeps its moving height: its text's own box, laid out the same at
          // any field height, and the field's edges and caps (style reads) give the end.
          const text = field.querySelector<HTMLElement>(":scope > .acpmux-md-root") ?? view.dom;
          const edges =
            px(style.paddingTop, 0) +
            px(style.paddingBottom, 0) +
            px(style.borderTopWidth, 0) +
            px(style.borderBottomWidth, 0);
          const natural = text.getBoundingClientRect().height + edges;
          const max = px(style.maxHeight, Number.POSITIVE_INFINITY);
          to = Math.max(px(style.minHeight, 0), Math.min(natural, max));
          capped = natural > max + 0.5;
          if (Math.abs(to - running.to) < 0.5) return;
        } else {
          to = field.getBoundingClientRect().height;
          if (Math.abs(to - shown) < 0.5) return;
          capped = field.scrollHeight > field.clientHeight + 1;
        }
        const from = shown;
        if (motionMode(field.ownerDocument) !== "full") {
          if (running) land(field);
          shown = to;
          return;
        }
        const lineHeight = Number.parseFloat(style.lineHeight) || 20;
        const reveal = capped || Math.abs(to - from) > lineHeight * REVEAL_LINES || (running?.reveal ?? false);
        if (!running) {
          // The height it drew, as the transition's start: a style flush, no layout.
          field.style.height = `${from}px`;
          field.getAnimations();
        }
        field.setAttribute(GROWTH_ATTRIBUTE, arm);
        field.style.height = `${to}px`;
        shown = to;
        // The transition the write starts (a style flush, no layout); a running one turns from the
        // height drawn. None when motion is off (Reduce Motion, a zero token).
        const animation = field.getAnimations().find((each) => (each as CSSTransition).transitionProperty === "height");
        if (!animation) {
          land(field);
          return;
        }
        const motion: Motion = { animation, to, reveal };
        moving.set(field, motion);
        // At the end height the text fits the field, so no thumb meanwhile.
        field.toggleAttribute(SETTLING_SCROLLER_ATTRIBUTE, !capped);
        const done = () => {
          if (moving.get(field) === motion) land(field);
        };
        animation.addEventListener("finish", done, { once: true });
        animation.addEventListener("cancel", done, { once: true });
        // The transcript takes the end height into its room now and moves its rows on this curve.
        const detail: FieldGrowthDetail = {
          to,
          easing: style.transitionTimingFunction || "ease",
          duration: Number(animation.effect?.getTiming().duration) || (cssTimeMs(style.transitionDuration) ?? 0),
          animation,
        };
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

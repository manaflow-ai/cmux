// The un-pop: a queued or held prompt the reader takes back before it went (its x in the queue,
// ComposerQueue.tsx `cancelEdit`) plays the reverse of its send (Leo, 2026-11-22: "unsending a
// message that didnt already get sent should have proper animations too, i think. an "un-pop"?").
// The send button's state-machine spec names this morph `unpop`.
//
// The x notes the row (`noteUnpopOrigin`) in its click, before the queue hides it: a copy of the
// row's words is drawn over the pane exactly where the row drew them, the row is hidden under it, and
// the queue keeps its height (min-height) so the rows above stay where they are while the host takes
// the prompt out. When its text comes back (Composer.tsx `restore` calls `playUnpop`) the field takes
// it in that frame, at its new height with no growth motion (fieldGrowth.ts: a value set from
// outside), the queue lets its height go in the same frame, and the copy moves into the field's text
// box on the move token (`--agent-motion-move`, the send's settling curve), reading where the field
// is each frame; the field's own text is hidden under it and shown in the frame it lands. Arms
// (unpop.experiment.ts): `fly`, `slide`, `pop`, and `instant`, which notes nothing: today's.
//
// Reduce Motion, the host's switch, a zero token, a hidden page and the minimal chat motion are
// instant (motionMode.ts), as is a row the queue had no copy for.
//
// Stop condition: one flight at a time; it ends when its clock ends (it lands), when the next un-pop
// starts, when the field leaves the page, or WAIT_MS after the x with no text come back (the
// host kept the prompt: the row and the queue's height come back as they were).
import { MOTION_EASE_OUT, MOTION_EASE_SEND, MOTION_MS } from "../../../motion/scale.generated";
import { experimentArm } from "../../../experiments/experiment";
import { motionMode } from "../../../ui/motion/motionMode";
import { entranceAllowed } from "../../shared/pageReveal";
import { cssTimeMs } from "./fold";
import { copyText, mix, mixRect, overlayLayer, radiusOf, rectOf, span, type Rect } from "./sendMorph";
import { composerUnpop } from "./unpop.experiment";

export type UnpopStyle = "fly" | "slide" | "pop" | "instant";

/// A row whose text does not come back within this ends its flight (the host kept the prompt).
const WAIT_MS = 1000;
/// The reverse pop's length at most: a quick beat, never a slow one.
const POP_MS = MOTION_MS.micro;
/// One frame at 60 Hz (ms).
const FRAME_MS = 16;

let flight: Unpop | undefined;

/// How long the un-pop runs for `node`, 0 when motion is off for its page (as the send's sendMs).
function unpopMs(node: Element): number {
  const doc = node.ownerDocument;
  if (motionMode(doc, node) !== "full" || !entranceAllowed(doc)) return 0;
  return cssTimeMs(getComputedStyle(node).getPropertyValue("--agent-motion-move")) ?? MOTION_MS.standard;
}

/// The x on queued row `row` takes its prompt back: unless the arm is instant or motion is off, a
/// copy of its words holds its place until the text is back in the composer (`playUnpop`). Called
/// in the click's task, before the queue hides the row. O(the row's nodes), once per un-pop.
export function noteUnpopOrigin(row: Element | null | undefined): void {
  flight?.land();
  if (!(row instanceof Element) || !row.isConnected || typeof row.animate !== "function") return;
  const style = experimentArm(composerUnpop);
  if (style === "instant") return;
  const duration = unpopMs(row);
  if (!(duration > 0)) return;
  flight = new Unpop(row as HTMLElement, style, duration);
}

/// The taken-back text is in the composer whose card is `box` (Composer.tsx `restore`, after the
/// field took it): the waiting copy moves into the field. Runs in the restore's task, before a paint.
export function playUnpop(box: Element | null | undefined): void {
  flight?.play(box ?? undefined);
}

/// Lands any un-pop at once (tests).
export function landUnpop(): void {
  flight?.land();
}

/// The morph the send button's state-machine spec references by name.
export const unpop = {
  name: "unpop",
  experiment: composerUnpop,
  note: noteUnpopOrigin,
  play: playUnpop,
  land: landUnpop,
} as const;

/// The row's clamp keeps its one line and ellipsis in its copy (copyText keeps each element's box
/// look, not its overflow).
const CLAMP_LOOK = ["white-space", "overflow", "text-overflow"] as const;

class Unpop {
  readonly layer: HTMLElement;
  readonly base: { left: number; top: number };
  /// The row's words, as the row drew them.
  readonly words: HTMLElement;
  readonly from: Rect;
  readonly rowRect: Rect;
  readonly rowRadius: number;
  /// The would-be bubble's glass (`fly`): it grows around the words and shrinks into the field.
  readonly glass?: HTMLElement;
  /// The field's words as it draws them now, moving in under the row's words (`fly`, `slide`).
  content?: HTMLElement;
  editor?: HTMLElement;
  field?: HTMLElement;
  fieldRadius = 0;
  editorOpacity = "";
  /// The queue the row was in, held at its height until the text is back.
  list?: HTMLElement;
  listMinHeight = "";
  rowVisibility: string;
  pop?: Animation;
  clock?: Animation;
  frame = 0;
  timer: ReturnType<typeof setTimeout>;
  played = false;
  ended = false;
  done = false;

  constructor(
    readonly row: HTMLElement,
    readonly style: Exclude<UnpopStyle, "instant">,
    readonly duration: number,
  ) {
    // Reads first (the row, its words, the queue), then writes.
    const source = row.querySelector<HTMLElement>(".acpmux-queued-text") ?? row;
    this.from = rectOf(source);
    this.rowRect = rectOf(row);
    this.rowRadius = radiusOf(row);
    const copy = copyText(source, this.from.width);
    // Each clamp's look first, then its copy's (reads before writes: one style pass).
    const looks = [...source.querySelectorAll(".acpmux-queued-clamp")].map((clamp) => {
      const look = getComputedStyle(clamp);
      return CLAMP_LOOK.map((property) => [property, look.getPropertyValue(property)] as const);
    });
    for (const [index, clamp] of copy.querySelectorAll<HTMLElement>(".acpmux-queued-clamp").entries())
      for (const [property, value] of looks[index] ?? []) clamp.style.setProperty(property, value);
    const list = row.closest<HTMLElement>(".acpmux-composer-queue") ?? undefined;
    const listHeight = list?.getBoundingClientRect().height ?? 0;
    this.layer = overlayLayer(row, "data-unpop-layer");
    const placed = this.layer.getBoundingClientRect();
    this.base = { left: placed.left, top: placed.top };
    if (style === "fly") {
      this.glass = this.piece("bubble", "ui-glass cv-user__bubble");
      Object.assign(this.glass.style, { padding: "0", maxWidth: "none", opacity: "0" });
      this.place(this.glass, this.rowRect, this.rowRadius);
    }
    this.words = this.piece("text");
    Object.assign(this.words.style, { overflow: "hidden", height: `${this.from.height}px` });
    this.words.appendChild(copy);
    this.move(this.words, this.from.left, this.from.top);
    // The row under its copy, and the queue at its height: the rows above stay where they are.
    this.rowVisibility = row.style.visibility;
    row.style.visibility = "hidden";
    if (list && listHeight > 0) {
      this.list = list;
      this.listMinHeight = list.style.minHeight;
      list.style.minHeight = `${listHeight}px`;
    }
    if (style === "pop") {
      const center = `${this.from.left - this.base.left + this.from.width / 2}px ${this.from.top - this.base.top + this.from.height / 2}px`;
      this.layer.style.transformOrigin = center;
      this.pop = this.layer.animate(
        [
          { transform: "scale(1)", opacity: 1 },
          { transform: "scale(0.9)", opacity: 0 },
        ],
        {
          duration: Math.min(duration, POP_MS),
          easing: MOTION_EASE_OUT,
          fill: "forwards",
        },
      );
      this.pop.onfinish = () => {
        if (this.played) this.land();
      };
    }
    this.timer = setTimeout(() => this.land(), WAIT_MS);
  }

  piece(kind: string, className = ""): HTMLElement {
    const element = this.layer.ownerDocument.createElement("div");
    if (className) element.className = className;
    element.setAttribute("data-unpop-ghost", kind);
    Object.assign(element.style, {
      position: "absolute",
      left: "0",
      top: "0",
      margin: "0",
      boxSizing: "border-box",
      visibility: "visible",
    });
    this.layer.appendChild(element);
    return element;
  }

  place(element: HTMLElement, rect: Rect, radius: number): void {
    element.style.left = `${rect.left - this.base.left}px`;
    element.style.top = `${rect.top - this.base.top}px`;
    element.style.width = `${rect.width}px`;
    element.style.height = `${rect.height}px`;
    element.style.borderRadius = `${radius}px`;
  }

  move(element: HTMLElement, left: number, top: number): void {
    element.style.translate = `${left - this.base.left}px ${top - this.base.top}px`;
  }

  play(box: Element | undefined): void {
    if (this.done || this.played) return;
    const editor = box?.querySelector<HTMLElement>(".acpmux-composer-prompt [contenteditable]") ?? undefined;
    const view = this.layer.ownerDocument.defaultView;
    if (!editor || !view) return this.land();
    this.played = true;
    clearTimeout(this.timer);
    this.editor = editor;
    // The queue lets its height go in the frame the field takes the text: one change of both.
    this.release();
    // The field's text under the copy until it lands.
    this.editorOpacity = editor.style.opacity;
    editor.style.opacity = "0";
    if (this.style === "pop") {
      // The text is in the field once the row has popped.
      if (!this.pop || this.pop.playState === "finished") this.land();
      return;
    }
    this.field = editor.closest<HTMLElement>(".acpmux-md-field") ?? editor;
    this.fieldRadius = radiusOf(this.field);
    const content = (this.content = this.piece("text"));
    content.appendChild(copyText(editor, rectOf(editor).width));
    content.style.opacity = "0";
    const easing = getComputedStyle(editor).getPropertyValue("--agent-ease-send").trim() || MOTION_EASE_SEND;
    // The clock only eases: it is held paused and set to each frame's time, so its progress is read in
    // the frame it is drawn. A running animation is pending until the compositor starts it, and its
    // first frame read the time it was set to again: the copy stood still a frame after it set off and
    // the un-pop drew as two motions (agent-pane-composer-unpop `phases: 2`).
    const clock = (this.clock = this.layer.animate([], { duration: this.duration, easing, fill: "forwards" }));
    clock.pause();
    clock.oncancel = () => this.land();
    // The copy is a frame along in the frame the field and the queue change, so all of it is one
    // motion (a still frame between them would be a second).
    const lead = Math.min(FRAME_MS, this.duration);
    const started = view.performance.now() - lead;
    let elapsed = lead;
    clock.currentTime = elapsed;
    this.draw(0);
    const step = (time: number) => {
      if (this.done) return;
      if (!editor.isConnected || this.ended) return this.land();
      // Each frame further along than the last, even one whose timestamp is from before play.
      elapsed = Math.min(this.duration, Math.max(time - started, elapsed + FRAME_MS));
      clock.currentTime = elapsed;
      this.ended = elapsed >= this.duration;
      this.draw(this.ended ? 1 : (clock.effect?.getComputedTiming().progress ?? 1));
      this.frame = view.requestAnimationFrame(step);
    };
    this.frame = view.requestAnimationFrame(step);
  }

  /// The copies `progress` (eased, 0 to 1) of the way into the field, reading where it is now.
  // perf-hot: one frame of the un-pop (reads the field's rects, writes the copies) unpopMorph.draw
  draw(progress: number): void {
    const to = rectOf(this.editor!);
    const field = this.field ? rectOf(this.field) : to;
    const left = mix(this.from.left, to.left, progress);
    const top = mix(this.from.top, to.top, progress);
    if (this.glass) {
      this.place(this.glass, mixRect(this.rowRect, field, progress), mix(this.rowRadius, this.fieldRadius, progress));
      // It grows around the words as they lift and is gone as they land in the field.
      this.glass.style.opacity = String(span(progress, 0, 0.25) * (1 - span(progress, 0.55, 1)));
    }
    this.move(this.words, left, top);
    this.words.style.opacity = String(1 - span(progress, 0, 0.5));
    if (this.content) {
      this.move(this.content, left, top);
      this.content.style.opacity = String(span(progress, 0.25, 0.85));
    }
  }

  release(): void {
    if (!this.list) return;
    this.list.style.minHeight = this.listMinHeight;
    this.list = undefined;
  }

  /// The copies go and the field's text (or, with no text back, the row) draws where they were.
  land(): void {
    if (this.done) return;
    this.done = true;
    clearTimeout(this.timer);
    this.layer.ownerDocument.defaultView?.cancelAnimationFrame(this.frame);
    if (this.clock) this.clock.oncancel = null;
    if (this.pop) this.pop.onfinish = null;
    this.layer.remove();
    this.release();
    this.row.style.visibility = this.rowVisibility;
    if (this.editor) this.editor.style.opacity = this.editorOpacity;
    if (flight === this) flight = undefined;
  }
}

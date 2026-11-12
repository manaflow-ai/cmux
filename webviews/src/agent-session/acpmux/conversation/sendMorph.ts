// A prompt sent from the latest row becomes its message in place (Leo, 2026-11-08, ask-157340f908:
// "if you're at the bottom or something, then the transformation applies whatever's in your composer
// into your depicted message"). The composer notes what it drew as it lets the prompt go
// (`noteSendOrigins`: its card, its words and a copy of them, each chip); the transcript's send says
// whether the view follows the latest row (`noteSendFromLatest`), and only then copies of those are
// drawn over the pane, in the frame the composer empties, exactly where the composer drew them. When
// the sent row mounts (`playSendMorph`) the copies move to the bubble and the thumbnails on the send
// motion (`--agent-motion-send`, its settling curve), the clock the thread rises on (followGlide.ts
// `sent`), reading where the row is each frame; the real bubble and thumbnails are hidden under them
// and shown in the frame they land, and the row's own entrance (conversation.css SEND-ENTRANCE) does
// not also play. The transcript's rows clip their paint and the dock covers them, so the move is drawn
// by copies in one layer over the pane, never by the rows themselves.
//
// Sent while scrolled up (a ride to the latest row, conversation/sendTuck.ts), with motion off
// (the host's switch, Reduce Motion, a zero token, the page away) or when nothing calls
// `noteSendFromLatest`, nothing is copied: the prompt fades in place (Leo, 2026-11-08, ask-104c134b68:
// a fly-in "is kind of weird" when not at the bottom).
//
// Stop condition: one flight at a time; it ends when its clock ends (it lands), when the row leaves
// the page, when the next send starts, or after ROW_MS with no sent row to land on.
import { MOTION_EASE_SEND, MOTION_SEND_MS } from "../../../motion/scale.generated";
import { motionMode } from "../../../ui/motion/motionMode";
import { entranceAllowed } from "../../shared/pageReveal";
import { cssTimeMs } from "./fold";

/// How the composer's prompt becomes its message. `shell` (the product's): a bubble's glass grows
/// out of the composer's card around the words and settles as the sent bubble while the words move
/// into it; `lift`: the words move up into the bubble, whose glass fills in behind them where it is;
/// `inplace`: nothing moves, the bubble fades in place (#38159). The gallery compares them through
/// `data-send-morph` on an ancestor (SendMorph.gallery.tsx).
export type SendMorphStyle = "shell" | "lift" | "inplace";
export const SEND_MORPHS: readonly SendMorphStyle[] = ["shell", "lift", "inplace"];
const PRODUCT: SendMorphStyle = "shell";

type Rect = { left: number; top: number; width: number; height: number };
type Chip = { rect: Rect; radius: number; copy: HTMLElement };
type Origin = {
  at: number;
  /// The composer's card and its corner radius.
  card?: { rect: Rect; radius: number };
  /// The words' box, a copy of them, whether they are one line, and their text; `clip`: how much of
  /// the box's top and bottom the field's scroller hid (a long draft scrolled).
  words?: { rect: Rect; copy: HTMLElement; oneLine: boolean; text: string; clip: { top: number; bottom: number } };
  /// Chips by attachment id, and by `path:` and a video's path (a sent video tile knows only that).
  chips: Map<string, Chip>;
};

/// What the composer noted is used only by a send the transcript sees at once.
const ORIGIN_MS = 1000;
/// A flight whose row does not draw within this ends (the send was refused or held).
const ROW_MS = 1000;

/// The composer's chips on screen by attachment id: the strip's slot and a chip placed in the text
/// register here (`chipRef`; attachmentIntake.tsx, inlineAttachments.tsx).
const chips = new Map<string, Element>();
/// On the pane's shell while copies of the composer's words fly: the composer hides its placeholder.
export const SEND_MORPH_ATTR = "data-send-morphing";
let pending: Origin | undefined;
let flight: Flight | undefined;
/// A prompt's row that mounted in this commit before the transcript's send effect ran (a row drawn
/// in the send's own commit: its layout effect runs before its transcript's). Cleared after the commit.
let mounted: HTMLElement | undefined;

/// A ref for the box that holds attachment `id`'s chip in the composer.
export function chipRef(id: string): (element: Element | null) => void {
  let held: Element | null = null;
  return (element) => {
    if (element) chips.set(id, (held = element));
    else if (held && chips.get(id) === held) chips.delete(id);
    if (!element) held = null;
  };
}

const rectOf = (element: Element): Rect => {
  const { left, top, width, height } = element.getBoundingClientRect();
  return { left, top, width, height };
};
const radiusOf = (element: Element) => Number.parseFloat(getComputedStyle(element).borderTopLeftRadius) || 0;

/// Text looks a copy keeps outside its own rules: the box's font and ink, and each element's own.
const TEXT_LOOK = [
  "font-family",
  "font-size",
  "font-weight",
  "font-style",
  "line-height",
  "letter-spacing",
  "color",
  "white-space",
  "overflow-wrap",
  "word-break",
  "font-feature-settings",
  "font-variant-ligatures",
  "text-align",
] as const;
const ELEMENT_LOOK = [
  "display",
  "margin",
  "padding",
  "font-weight",
  "font-style",
  "font-family",
  "font-size",
  "color",
  "background-color",
  "border-radius",
  "text-decoration-line",
] as const;

/// A copy of `source`'s children in a box of `width` with `source`'s text look; each element keeps
/// its own drawn look (the copy is outside the rules that drew it). O(copied nodes), once per send.
function copyText(source: Element, width: number): HTMLElement {
  const box = source.ownerDocument.createElement("div");
  const look = getComputedStyle(source);
  for (const property of TEXT_LOOK) box.style.setProperty(property, look.getPropertyValue(property));
  box.style.width = `${width}px`;
  for (const child of source.childNodes) {
    const copy = child.cloneNode(true);
    if (copy instanceof Element && child instanceof Element) keepLook(child, copy);
    box.appendChild(copy);
  }
  for (const element of box.querySelectorAll("[id], [contenteditable], [tabindex]")) {
    element.removeAttribute("id");
    element.removeAttribute("contenteditable");
    element.removeAttribute("tabindex");
  }
  return box;
}
function keepLook(source: Element, copy: Element): void {
  // An HTML or SVG element (each has a style); read off the node, not a global its page may lack.
  if ("style" in copy && copy.style instanceof Object) {
    const look = getComputedStyle(source);
    for (const property of ELEMENT_LOOK)
      (copy as HTMLElement).style.setProperty(property, look.getPropertyValue(property));
  }
  for (let index = 0; index < source.children.length; index += 1) {
    const from = source.children[index]!;
    const to = copy.children[index];
    if (to) keepLook(from, to);
  }
}

/// Records what the composer draws of the prompt it sends, before it lets it go: its card (`box`, or
/// the card around it), its words and the chips of `attachments`. O(sent attachments + typed nodes).
export function noteSendOrigins(
  attachments: readonly { id: string; path?: string }[],
  box?: Element | null,
  now = performance.now(),
): void {
  // A flight still in the air lands at once: the next prompt's copies are the ones drawn now.
  flight?.land();
  const origin: Origin = { at: now, chips: new Map() };
  const card = box?.closest(".acpmux-composer-box") ?? box?.querySelector(".acpmux-composer-box") ?? box;
  if (card?.isConnected) {
    origin.card = { rect: rectOf(card), radius: radiusOf(card) };
    const editor = card.querySelector<HTMLElement>(".acpmux-composer-prompt [contenteditable]");
    const text = editor?.textContent?.trim() ?? "";
    if (editor && text) {
      const rect = rectOf(editor);
      const lineHeight = Number.parseFloat(getComputedStyle(editor).lineHeight) || 20;
      const copy = copyText(editor, rect.width);
      // A chip placed in the text moves on its own (below), not with the words.
      for (const chip of copy.querySelectorAll<HTMLElement>(".acpmux-md-inline-chip")) chip.style.visibility = "hidden";
      // The field's scroller between the editor and the card clips a long draft: so does its copy.
      let clip = { top: 0, bottom: 0 };
      for (let at = editor.parentElement; at && at !== card; at = at.parentElement)
        if (at.scrollHeight > at.clientHeight + 1 && getComputedStyle(at).overflowY !== "visible") {
          const shown = rectOf(at);
          clip = {
            top: Math.max(0, shown.top - rect.top),
            bottom: Math.max(0, rect.top + rect.height - (shown.top + shown.height)),
          };
          break;
        }
      origin.words = { rect, copy, oneLine: rect.height < lineHeight * 1.5, text, clip };
    }
  }
  for (const attachment of attachments) {
    const slot = chips.get(attachment.id);
    if (!slot?.isConnected) continue;
    // The strip's slot draws nothing of its own (display: contents): its chip has the box.
    const shown = slot.querySelector(".acpmux-attachment") ?? slot;
    const rect = rectOf(shown);
    if (!(rect.width > 0) || !(rect.height > 0)) continue;
    const image = shown.querySelector("img");
    const copy = shown.ownerDocument.createElement("div");
    if (image?.currentSrc || image?.src) {
      const picture = shown.ownerDocument.createElement("img");
      picture.src = image.currentSrc || image.src;
      picture.alt = "";
      Object.assign(picture.style, { width: "100%", height: "100%", objectFit: "cover", display: "block" });
      copy.appendChild(picture);
    }
    const chip = { rect, radius: radiusOf(shown), copy };
    origin.chips.set(attachment.id, chip);
    if (attachment.path) origin.chips.set(`path:${attachment.path}`, chip);
  }
  pending = origin;
}

/// The send motion's length for `node` (`--agent-motion-send`), 0 when motion is off for its page:
/// the shared gate (ui/motion/motionMode.ts: the host's switch, a zero token, Reduce Motion, a
/// hidden page) and a page whose first frame back has not passed (entranceAllowed).
function sendMs(node: Element): number {
  const doc = node.ownerDocument;
  if (motionMode(doc) !== "full" || !entranceAllowed(doc)) return 0;
  return cssTimeMs(getComputedStyle(node).getPropertyValue("--agent-motion-send")) ?? MOTION_SEND_MS;
}

/// The transcript's word on the send the composer just noted: `fromLatest` when the view follows the
/// latest row as the reader sends (VirtualTranscript's send effect; `scroller` is its scroller). Only
/// then, with motion on and the composer emptied, the copies are drawn where the composer drew the
/// prompt, held there until the sent row mounts. Runs in the send's commit, before it paints.
export function noteSendFromLatest(fromLatest: boolean, scroller: HTMLElement, now = performance.now()): void {
  const origin = pending;
  pending = undefined;
  if (!fromLatest || !origin || now - origin.at > ORIGIN_MS || typeof scroller.animate !== "function") return;
  const style = (scroller.closest("[data-send-morph]")?.getAttribute("data-send-morph") ?? PRODUCT) as SendMorphStyle;
  if (style === "inplace" || !SEND_MORPHS.includes(style)) return;
  const duration = sendMs(scroller);
  if (!(duration > 0)) return;
  if (!origin.words && origin.chips.size === 0) return;
  flight = new Flight(origin, style, duration, scroller);
  if (mounted?.isConnected && scroller.contains(mounted)) flight.claim(mounted);
  mounted = undefined;
}

/// The sent row `row` mounted (VirtualTranscript's row frame, a prompt entering): if a flight waits
/// for it, the copies move to its bubble and thumbnails from now. Once per send.
export function playSendMorph(row: HTMLElement): boolean {
  const waiting = flight;
  if (!waiting || waiting.row) {
    // The send's own commit may draw the row before its transcript hears of the send (above).
    mounted = row;
    queueMicrotask(() => {
      if (mounted === row) mounted = undefined;
    });
    return false;
  }
  return waiting.claim(row);
}

/// The composer keeps the prompt it noted (until the host takes it, or for good): nothing leaves it,
/// so nothing is copied. Called in the same task as the send, before a frame paints.
export function keepSendOrigins(): void {
  pending = undefined;
  flight?.land();
}

/// Forgets every noted chip and lands any flight (tests).
export function clearSendOrigins(): void {
  flight?.land();
  pending = undefined;
  chips.clear();
}

const mix = (from: number, to: number, progress: number) => from + (to - from) * progress;
const mixRect = (from: Rect, to: Rect, progress: number): Rect => ({
  left: mix(from.left, to.left, progress),
  top: mix(from.top, to.top, progress),
  width: mix(from.width, to.width, progress),
  height: mix(from.height, to.height, progress),
});
/// 0 before `from`, 1 after `to`, linear between.
const span = (progress: number, from: number, to: number) => Math.min(1, Math.max(0, (progress - from) / (to - from)));

/// `place`: the target's place among the row's previews, where a remounted one is found again.
type Piece = {
  ghost: HTMLElement;
  chip: Chip;
  target?: HTMLElement;
  place?: number;
  radius: number;
  overlay?: HTMLElement;
};

class Flight {
  readonly layer: HTMLElement;
  /// The layer's own place: copies are placed in its box, from viewport rects.
  readonly base: { left: number; top: number };
  readonly glass: HTMLElement;
  readonly typed?: HTMLElement;
  shell?: HTMLElement;
  /// The shell's glass opacity as it starts: 1 under a raised composer's words (below).
  glassFrom = 0;
  content?: HTMLElement;
  row?: HTMLElement;
  bubble?: HTMLElement;
  pad = { left: 0, top: 0 };
  bubbleRadius = 0;
  /// The sent bubble's words are the typed words as the composer laid them out: one copy moves.
  same = false;
  /// The chips' copies by either key, and each once.
  readonly pieces = new Map<string, Piece>();
  readonly copies: Piece[] = [];
  readonly hidden: HTMLElement[] = [];
  clock?: Animation;
  /// The copies fading where they are: no sent row came (the prompt was queued behind a turn).
  fade?: Animation;
  frame = 0;
  timer: ReturnType<typeof setTimeout>;
  ended = false;
  done = false;

  constructor(
    readonly origin: Origin,
    readonly style: Exclude<SendMorphStyle, "inplace">,
    readonly duration: number,
    readonly scroller: HTMLElement,
  ) {
    const doc = scroller.ownerDocument;
    // Over the pane, above its dock (the composer) and its transcript's mask.
    this.layer = doc.createElement("div");
    this.layer.setAttribute("aria-hidden", "true");
    this.layer.setAttribute("data-send-morph-layer", "");
    Object.assign(this.layer.style, {
      position: "fixed",
      inset: "0",
      zIndex: "var(--layer-overlay)",
      pointerEvents: "none",
      contain: "strict",
    });
    const shell = scroller.closest(".acpmux-shell");
    (shell ?? doc.body).appendChild(this.layer);
    // The composer has emptied under the words' copy: its placeholder stays out of the copy's way
    // until the copies land (markdownField.css), so no frame draws two texts in one field.
    if (this.origin.words && shell instanceof HTMLElement) {
      shell.setAttribute(SEND_MORPH_ATTR, "");
      this.shell = shell;
    }
    const placed = this.layer.getBoundingClientRect();
    this.base = { left: placed.left, top: placed.top };
    // The bubble's glass: the sent bubble's own rules (conversation.css .cv-user__bubble in the pane).
    this.glass = this.piece("bubble", "ui-glass cv-user__bubble");
    Object.assign(this.glass.style, { padding: "0", maxWidth: "none", opacity: "0" });
    const card = origin.card?.rect ?? origin.words?.rect;
    if (card) this.place(this.glass, card, origin.card?.radius ?? 0);
    // A raised composer (a draft of more than a line) shrinks to its one line as it empties, before
    // the sent row mounts: its words' copy would float over the transcript with no card under them,
    // so the glass is drawn under them from the start.
    if (style === "shell" && origin.card && origin.words && !origin.words.oneLine) {
      this.glassFrom = 1;
      this.glass.style.opacity = "1";
    }
    if (origin.words) {
      this.typed = this.piece("text");
      this.typed.appendChild(origin.words.copy);
      const { top, bottom } = origin.words.clip;
      if (top > 0 || bottom > 0) this.typed.style.clipPath = `inset(${top}px 0 ${bottom}px 0)`;
      this.move(this.typed, origin.words.rect.left, origin.words.rect.top);
    }
    // One copy per chip, found by either of its keys (a video's id and its path).
    const made = new Map<Chip, Piece>();
    for (const [key, chip] of origin.chips) {
      let piece = made.get(chip);
      if (!piece) {
        const ghost = this.piece("attachment");
        ghost.style.overflow = "hidden";
        ghost.appendChild(chip.copy);
        Object.assign(chip.copy.style, { position: "absolute", inset: "0" });
        this.place(ghost, chip.rect, chip.radius);
        made.set(chip, (piece = { ghost, chip, radius: chip.radius }));
        this.copies.push(piece);
      }
      this.pieces.set(key, piece);
    }
    this.timer = setTimeout(() => this.land(), ROW_MS);
    // The sent row draws in the send's commit or the next: a prompt queued behind a running turn
    // draws none (the queue shows it over the composer), so its copies fade where they are.
    const view = doc.defaultView;
    if (view)
      this.frame = view.requestAnimationFrame(() => {
        this.frame = view.requestAnimationFrame(() => {
          if (this.row || this.done) return;
          // Only the words fade where they are: the card's glass under a raised draft (above) would
          // fade over the queue and the transcript as a box with nothing in it.
          if (this.glassFrom > 0) this.glass.style.opacity = "0";
          this.fade = this.layer.animate([{ opacity: 1 }, { opacity: 0 }], {
            duration: this.duration,
            easing: "ease-out",
            fill: "forwards",
          });
          this.fade.onfinish = () => this.land();
        });
      });
  }

  piece(kind: string, className = ""): HTMLElement {
    const element = this.layer.ownerDocument.createElement("div");
    if (className) element.className = className;
    element.setAttribute("data-send-morph-ghost", kind);
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

  claim(row: HTMLElement): boolean {
    const doc = row.ownerDocument;
    const view = doc.defaultView;
    if (!view || this.done) return false;
    this.row = row;
    clearTimeout(this.timer);
    view.cancelAnimationFrame(this.frame);
    if (this.fade) {
      this.fade.onfinish = null;
      this.fade.cancel();
      this.fade = undefined;
    }
    // Its entrance is this move: the row's fade and the bubble's opening do not also play.
    row.setAttribute("data-send-morphed", "");
    const bubble = row.querySelector<HTMLElement>(".cv-user__bubble") ?? undefined;
    if (bubble) {
      this.bubble = bubble;
      const look = getComputedStyle(bubble);
      this.pad = { left: Number.parseFloat(look.paddingLeft) || 0, top: Number.parseFloat(look.paddingTop) || 0 };
      this.bubbleRadius = Number.parseFloat(look.borderTopLeftRadius) || 0;
      // Its exact (fractional) width: a rounded one wraps a line that just fits.
      const width =
        bubble.getBoundingClientRect().width -
        this.pad.left -
        (Number.parseFloat(look.paddingRight) || 0) -
        (Number.parseFloat(look.borderLeftWidth) || 0) -
        (Number.parseFloat(look.borderRightWidth) || 0);
      const content = (this.content = this.piece("text"));
      const copy = copyText(bubble, width);
      content.appendChild(copy);
      // A preview drawn in the words has its own copy (below).
      for (const preview of copy.querySelectorAll<HTMLElement>("[data-send-key]")) preview.style.visibility = "hidden";
      // One line in the composer and one in the bubble, the same words: the words move as they are.
      const words = this.origin.words;
      const line = Number.parseFloat(look.lineHeight) || 20;
      this.same =
        !!words &&
        words.oneLine &&
        bubble.clientHeight - 2 * this.pad.top < line * 1.5 &&
        (bubble.textContent ?? "").trim() === words.text;
      if (this.same) this.typed?.remove();
      content.style.opacity = this.same ? "1" : "0";
    }
    // Each preview's place first, then its copy (reads before writes: one layout).
    const landing: Piece[] = [];
    for (const [place, preview] of row.querySelectorAll<HTMLElement>("[data-send-key]").entries()) {
      const piece = this.pieces.get(preview.dataset.sendKey!);
      if (!piece || piece.target) continue;
      piece.target = preview;
      piece.place = place;
      piece.radius = Number.parseFloat(getComputedStyle(preview).borderTopLeftRadius) || 0;
      landing.push(piece);
    }
    for (const piece of landing) {
      const preview = piece.target!;
      // The preview's own drawing (a badge, a play mark), over the chip's picture as it lands.
      const overlay = doc.createElement("span");
      overlay.className = "cv-user__inline-image";
      Object.assign(overlay.style, {
        position: "absolute",
        inset: "0",
        display: "block",
        maxWidth: "none",
        opacity: "0",
        margin: "0",
      });
      const copy = preview.cloneNode(true) as HTMLElement;
      copy.removeAttribute("id");
      copy.classList.remove("cv-enter");
      Object.assign(copy.style, { width: "100%", height: "100%", maxWidth: "none", visibility: "visible" });
      for (const image of [copy, ...copy.querySelectorAll<HTMLElement>("img")])
        if (image instanceof HTMLImageElement)
          Object.assign(image.style, { width: "100%", height: "100%", objectFit: "cover" });
      overlay.appendChild(copy);
      piece.ghost.appendChild(overlay);
      piece.overlay = overlay;
    }
    // Hidden under their copies until they land.
    for (const element of [bubble, ...this.copies.map((piece) => piece.target)]) if (element) this.hide(element);
    // The send motion's clock: the copies' progress each frame is its eased progress.
    const easing = getComputedStyle(this.scroller).getPropertyValue("--agent-ease-send").trim() || MOTION_EASE_SEND;
    this.clock = this.layer.animate([], { duration: this.duration, easing });
    this.clock.oncancel = () => this.land();
    this.draw(0);
    // Stops when the row leaves the page, the clock is cancelled (land), or once the copies have
    // drawn one frame at the row after the clock ended: the row then shows where they were.
    const step = () => {
      if (this.done) return;
      if (!row.isConnected || this.ended) return this.land();
      this.ended = this.clock!.playState === "finished";
      this.draw(this.ended ? 1 : (this.clock!.effect?.getComputedTiming().progress ?? 1));
      this.frame = view.requestAnimationFrame(step);
    };
    this.frame = view.requestAnimationFrame(step);
    return true;
  }

  hide(element: HTMLElement): void {
    if (element.style.visibility === "hidden") return;
    element.style.visibility = "hidden";
    this.hidden.push(element);
  }

  /// The row's bubble and previews now: the host's echo of the prompt can draw them again within the
  /// flight (an image's lasting id replaces the composer's, which remounts its thumbnail), and the
  /// copies follow the new ones, found at the same place in the row, hidden under them as well.
  rebind(): void {
    const row = this.row;
    if (!row) return;
    if (this.bubble && !this.bubble.isConnected) {
      this.bubble = row.querySelector<HTMLElement>(".cv-user__bubble") ?? undefined;
      if (this.bubble) this.hide(this.bubble);
    }
    let previews: NodeListOf<HTMLElement> | undefined;
    for (const piece of this.copies) {
      if (!piece.target || piece.target.isConnected || piece.place === undefined) continue;
      previews ??= row.querySelectorAll<HTMLElement>("[data-send-key]");
      piece.target = previews[piece.place];
      if (piece.target) this.hide(piece.target);
    }
  }

  /// The copies `progress` (eased, 0 to 1) of the way, reading where the row is now.
  // perf-hot: one frame of the send motion (reads the bubble's and previews' rects, writes the copies) sendMorph.draw
  draw(progress: number): void {
    const words = this.origin.words;
    const card = this.origin.card;
    this.rebind();
    // Where the row draws them now (it may be rising), all read before any copy moves.
    const to = this.bubble ? rectOf(this.bubble) : undefined;
    const slots = this.copies.map((piece) => (piece.target ? rectOf(piece.target) : undefined));
    if (to) {
      const glass = this.style === "shell" && card ? mixRect(card.rect, to, progress) : to;
      this.place(
        this.glass,
        glass,
        this.style === "shell" && card ? mix(card.radius, this.bubbleRadius, progress) : this.bubbleRadius,
      );
      // The shell's glass grows out of the card; the lift's fills in where the bubble is.
      this.glass.style.opacity = String(
        this.style === "shell" ? mix(this.glassFrom, 1, span(progress, 0, 0.45)) : progress,
      );
      const end = { left: to.left + this.pad.left, top: to.top + this.pad.top };
      const start = words?.rect ?? end;
      const left = mix(start.left, end.left, progress);
      const top = mix(start.top, end.top, progress);
      if (this.content) {
        this.move(this.content, left, top);
        if (!this.same) this.content.style.opacity = String(span(progress, 0.25, 0.85));
      }
      if (this.typed && !this.same) {
        this.move(this.typed, left, top);
        this.typed.style.opacity = String(1 - span(progress, 0, 0.5));
      }
    } else if (this.typed) this.typed.style.opacity = String(1 - progress);
    for (const [index, piece] of this.copies.entries()) {
      const slot = slots[index];
      if (!slot) {
        piece.ghost.style.opacity = String(1 - progress);
        continue;
      }
      this.place(piece.ghost, mixRect(piece.chip.rect, slot, progress), mix(piece.chip.radius, piece.radius, progress));
      if (piece.overlay) piece.overlay.style.opacity = String(span(progress, 0.4, 1));
    }
  }

  /// The copies go and the row's own bubble and previews draw where they were, in one frame.
  land(): void {
    if (this.done) return;
    this.done = true;
    clearTimeout(this.timer);
    this.layer.ownerDocument.defaultView?.cancelAnimationFrame(this.frame);
    if (this.clock) this.clock.oncancel = null;
    if (this.fade) this.fade.onfinish = null;
    this.layer.remove();
    this.shell?.removeAttribute(SEND_MORPH_ATTR);
    for (const element of this.hidden) element.style.visibility = "";
    if (flight === this) flight = undefined;
  }
}

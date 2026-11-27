// New Tab's composer and the chat's are two elements: New Tab's sits high on its page, the chat's
// docks at the bottom. A start swaps one for the other in a single frame, so without this the box the
// person just typed in jumped about 370 px down on the frame the chat drew (Leo, 2026-11-17: "the
// layout shift when starting a new chat"; test/new-chat-start-no-shift.test.ts measured it).
//
// New Tab holds where its card and its field drew as it leaves; the chat's composer, when it mounts,
// starts from there and settles home on the shared move token and spring (Leo, 2026-11-17: "chats
// settle with no unnecessary layout shifts after they start"). Both cards are the column's width, so
// the moves are what differs between the two surfaces:
// - the card: New Tab's sits under its location strip, so the chat's whole composer glides from New
//   Tab's card top, not from its strip;
// - the card's height: New Tab's quiet row sits under its card and the chat's inside it, so the chat's
//   card opens from New Tab's height (a clip from the bottom, no relayout);
// - the field: New Tab's leads with the input glyph, so the chat's field slides in from where New
//   Tab's text stood.
// No new element draws: the same card and field move.
import { MOTION_EASE_OUT, MOTION_SPRING } from "../../../motion/scale.generated";
import { declareMove } from "../../../layout/motionContract";
import { motionMode, springEasing } from "../../../ui/motion/motionMode";

type Place = { left: number; top: number; width: number; height: number };
type Held = { card: Place; field?: Place; at: number };
let held: Held | undefined;
/// A held place older than this belongs to a start that never drew a chat.
const HELD_MS = 2_000;

const NEW_TAB_CARD = ".nt-box";
/// The text's own box first: `.nt-field` alone also holds its padding.
const NEW_TAB_FIELD = ['.nt-field [contenteditable="true"]', ".nt-field"];
const CHAT_CARD = ":scope > .acpmux-composer-box";
/// The editor's root stands where its text will: the editable itself mounts after the composer does.
const CHAT_FIELD = ['[contenteditable="true"]', ".acpmux-md-root"];

function first(doc: ParentNode, selectors: string[]): Element | null {
  for (const selector of selectors) {
    const found = doc.querySelector(selector);
    if (found) return found;
  }
  return null;
}

function place(element: Element | null | undefined, laidOut = (rect: DOMRect) => rect.height > 0): Place | undefined {
  const rect = element?.getBoundingClientRect();
  return rect && laidOut(rect) ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height } : undefined;
}

/// A field's place is where its text starts: the editor's root is laid out but still empty (no height)
/// when the composer mounts, as its editable mounts after it, so a width alone places it.
const fieldPlace = (element: Element | null | undefined) => place(element, (rect) => rect.width > 0);

/** Called as New Tab leaves for the chat it started: remembers where its card and field drew. */
export function holdComposerPlace(doc: Document = document): void {
  const card = place(doc.querySelector(NEW_TAB_CARD));
  held = card ? { card, field: place(first(doc, NEW_TAB_FIELD)), at: performance.now() } : undefined;
}

function moveMs(element: Element): number {
  const view = element.ownerDocument.defaultView;
  if (!view) return 0;
  const token = view.getComputedStyle(element).getPropertyValue("--agent-motion-move").trim();
  const ms = Number.parseFloat(token);
  return token.endsWith("ms") ? ms : token.endsWith("s") ? ms * 1000 : Number.isFinite(ms) ? ms : 0;
}

/** Called once as the chat's composer mounts: settles it from New Tab's held places, if they are fresh. */
export function glideComposerFromHeld(form: HTMLElement | null): void {
  const from = held;
  held = undefined;
  if (!form || !from || performance.now() - from.at > HELD_MS) return;
  const mode = motionMode(form.ownerDocument, form);
  const duration = moveMs(form);
  if (mode === "none" || !(duration > 0) || typeof form.animate !== "function") return;
  // Every place is read before anything moves: a started animation's transform shows in the rects.
  const cardElement = form.querySelector<HTMLElement>(CHAT_CARD);
  const card = place(cardElement) ?? place(form);
  const fieldElement = first(form, CHAT_FIELD) as HTMLElement | null;
  const field = fieldPlace(fieldElement);
  if (!card) return;
  const timing: KeyframeAnimationOptions = {
    duration,
    easing: mode === "full" ? springEasing(MOTION_SPRING, MOTION_EASE_OUT, form.ownerDocument) : MOTION_EASE_OUT,
  };
  const dy = from.card.top - card.top;
  const glides: Animation[] = [];
  if (Math.abs(dy) >= 1)
    glides.push(form.animate([{ transform: `translateY(${dy}px)` }, { transform: "none" }], timing));
  // The card opens from New Tab's height to its own.
  const hidden = card.height - from.card.height;
  if (cardElement && hidden >= 1) {
    const radius = getComputedStyle(cardElement).borderBottomLeftRadius || "0px";
    glides.push(
      cardElement.animate(
        [{ clipPath: `inset(0 0 ${hidden}px 0 round ${radius})` }, { clipPath: `inset(0 0 0 0 round ${radius})` }],
        timing,
      ),
    );
  }
  // The field slides from where New Tab's text stood inside its card.
  if (fieldElement && field && from.field) {
    const fx = from.field.left - field.left;
    const fy = from.field.top - from.card.top - (field.top - card.top);
    if (Math.abs(fx) >= 1 || Math.abs(fy) >= 1)
      glides.push(fieldElement.animate([{ transform: `translate(${fx}px, ${fy}px)` }, { transform: "none" }], timing));
  }
  // The glide is a script animation, and the layout-motion judge reads keyframe CSS animations only, so
  // without a declaration every frame of it read as an undeclared composer move (composer-send-one-motion:
  // the bar and its glass, 2 per state; hq#13423). It is declared as what it is, the composer entering
  // (schemas/layout-motion/contract.json `enter` on the composer surface), on the form, for exactly as
  // long as the glide plays: it ends when every part finishes or is cancelled. A composer move outside
  // the glide is still judged.
  if (glides.length === 0) return;
  const undeclare = declareMove({ event: "enter", scope: "targets", targets: [form], by: "composer handover glide" });
  void Promise.allSettled(glides.map((glide) => glide.finished)).then(undeclare);
}

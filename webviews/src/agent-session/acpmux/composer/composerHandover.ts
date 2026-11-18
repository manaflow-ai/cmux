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
// - the card's height: the two cards differ (Codex's chat card is taller than New Tab's, Claude's is
//   shorter: 48 px against 50.8), so the chat's card morphs from New Tab's height to its own either way;
// - the field: New Tab's leads with the input glyph, so the chat's field slides in from where New
//   Tab's text stood.
// No new element draws: the same card and field move.
import { MOTION_EASE_OUT, MOTION_SPRING } from "../../../motion/scale.generated";
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

function place(element: Element | null | undefined): Place | undefined {
  const rect = element?.getBoundingClientRect();
  return rect && rect.height > 0
    ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
    : undefined;
}

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

/// The chat's card goes from New Tab's height FROM to its own TO. A taller card opens with a clip from
/// the bottom (no relayout). A shorter one starts drawn at New Tab's height and closes to its own: a
/// negative bottom margin of the difference keeps its footprint at its own height, so nothing around
/// it relays out and its top stays where New Tab's was.
function morphCardHeight(cardElement: HTMLElement, from: number, to: number, timing: KeyframeAnimationOptions): void {
  const style = getComputedStyle(cardElement);
  const radius = style.borderBottomLeftRadius || "0px";
  const hidden = to - from;
  if (hidden >= 1) {
    cardElement.animate(
      [{ clipPath: `inset(0 0 ${hidden}px 0 round ${radius})` }, { clipPath: `inset(0 0 0 0 round ${radius})` }],
      timing,
    );
    return;
  }
  if (hidden > -1) return;
  // `height` is the content box unless the card says border-box.
  const edges =
    style.boxSizing === "border-box"
      ? 0
      : ["paddingTop", "paddingBottom", "borderTopWidth", "borderBottomWidth"].reduce(
          (sum, key) => sum + (Number.parseFloat(style[key as "paddingTop"]) || 0),
          0,
        );
  const margin = Number.parseFloat(style.marginBottom) || 0;
  cardElement.animate(
    [
      { height: `${from - edges}px`, marginBottom: `${margin + hidden}px` },
      { height: `${to - edges}px`, marginBottom: `${margin}px` },
    ],
    timing,
  );
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
  const field = place(fieldElement);
  if (!card) return;
  (window as unknown as Record<string, unknown>).__cmuxGlideProbe = {
    from,
    card,
    field,
    fieldTag: fieldElement ? `${fieldElement.tagName}.${fieldElement.className}` : null,
  };
  const timing: KeyframeAnimationOptions = {
    duration,
    easing: mode === "full" ? springEasing(MOTION_SPRING, MOTION_EASE_OUT, form.ownerDocument) : MOTION_EASE_OUT,
  };
  const dy = from.card.top - card.top;
  if (Math.abs(dy) >= 1) form.animate([{ transform: `translateY(${dy}px)` }, { transform: "none" }], timing);
  // The card morphs from New Tab's height to its own, taller or shorter.
  if (cardElement) morphCardHeight(cardElement, from.card.height, card.height, timing);
  // The field slides from where New Tab's text stood inside its card.
  if (fieldElement && field && from.field) {
    const fx = from.field.left - field.left;
    const fy = from.field.top - from.card.top - (field.top - card.top);
    if (Math.abs(fx) >= 1 || Math.abs(fy) >= 1)
      fieldElement.animate([{ transform: `translate(${fx}px, ${fy}px)` }, { transform: "none" }], timing);
  }
}

// New Tab's composer and the chat's are two elements: New Tab's sits high on its page, the chat's
// docks at the bottom. A start swaps one for the other in a single frame, so without this the box the
// person just typed in jumped about 370 px down on the frame the chat drew (Leo, 2026-11-17: "the
// layout shift when starting a new chat"; test/new-chat-start-no-shift.test.ts measured it).
// New Tab holds its box's place as it leaves; the chat's composer, when it mounts, starts at that place
// and glides home on the shared move token and spring. No new element draws: the same box moves.
import { MOTION_EASE_OUT, MOTION_SPRING } from "../../../motion/scale.generated";
import { motionMode, springEasing } from "../../../ui/motion/motionMode";

type Held = { top: number; at: number };
let held: Held | undefined;
/// A held place older than this belongs to a start that never drew a chat.
const HELD_MS = 2_000;

/** Called as New Tab leaves for the chat it started: remembers where its composer box drew. */
export function holdComposerPlace(doc: Document = document): void {
  const box = doc.querySelector(".nt-composer");
  const rect = box?.getBoundingClientRect();
  held = rect && rect.height > 0 ? { top: rect.top, at: performance.now() } : undefined;
}

function moveMs(element: Element): number {
  const view = element.ownerDocument.defaultView;
  if (!view) return 0;
  const token = view.getComputedStyle(element).getPropertyValue("--agent-motion-move").trim();
  const ms = Number.parseFloat(token);
  return token.endsWith("ms") ? ms : token.endsWith("s") ? ms * 1000 : Number.isFinite(ms) ? ms : 0;
}

/** Called once as the chat's composer mounts: glides it from New Tab's held place, if one is fresh. */
export function glideComposerFromHeld(element: HTMLElement | null): void {
  const from = held;
  held = undefined;
  if (!element || !from || performance.now() - from.at > HELD_MS) return;
  const dy = from.top - element.getBoundingClientRect().top;
  if (Math.abs(dy) < 1) return;
  const mode = motionMode(element.ownerDocument, element);
  const duration = moveMs(element);
  if (mode === "none" || !(duration > 0) || typeof element.animate !== "function") return;
  element.animate([{ transform: `translateY(${dy}px)` }, { transform: "none" }], {
    duration,
    easing: mode === "full" ? springEasing(MOTION_SPRING, MOTION_EASE_OUT, element.ownerDocument) : MOTION_EASE_OUT,
  });
}

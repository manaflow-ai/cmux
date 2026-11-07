// A sent attachment's way from the composer into its bubble (Leo, 2026-11-07: "when an attachment is
// inside of the composer, it's at a smaller size, and when it gets sent up, it gets slightly
// expanded just a bit. And that recalculation is jarring"). The composer's chip and the sent
// thumbnail differ in size, so the send is one planned move: the composer notes where each chip it
// sends is (`noteSendOrigins`), and the sent thumbnail or video tile, laid out at its final size and
// place from its first frame (UserBubble.tsx sentImageSize, SentVideoTile.tsx), draws that first
// frame over the chip and moves to its slot. Transform only: the row's height, the text beside the
// preview and every row around it are where they end from the first frame, so nothing reflows
// when the move ends or the image loads. With motion off (the host's switch, Reduce Motion, a zero
// token, the page away) the thumbnail draws in its slot at once.
import { MOTION_MS } from "../../../motion/scale.generated";
import { entranceAllowed } from "../../shared/pageReveal";

/// How the sent preview comes in: `move` (the product's) goes from the chip's place and size to its
/// slot; `grow` scales up from the chip's size in its slot; `fade` is the row's own fade only. The
/// gallery compares them (SendTransition.gallery.tsx) through `data-send-morph` on an ancestor.
export type SendMorphStyle = "move" | "grow" | "fade";

type Origin = { rect: DOMRect; at: number };

/// A chip's place is used only by a sent row drawn soon after the send; later it is stale.
const ORIGIN_MS = 2000;
/// Chips' places by attachment id and, for a video, by its path (a sent video tile knows only that).
const origins = new Map<string, Origin>();

/// Records where each of `attachments`' chips is in the composer, before the composer lets them go.
/// The strip's slot and a chip placed in the text carry `data-attachment-id` (attachmentIntake.tsx,
/// inlineAttachments.tsx). O(sent attachments).
export function noteSendOrigins(
  attachments: readonly { id: string; path?: string }[],
  doc: Document | undefined = typeof document === "undefined" ? undefined : document,
  now = performance.now(),
): void {
  if (!doc) return;
  for (const [key, origin] of origins) if (now - origin.at > ORIGIN_MS) origins.delete(key);
  for (const attachment of attachments) {
    const slot = doc.querySelector(`[data-attachment-id="${CSS.escape(attachment.id)}"]`);
    const chip = slot?.querySelector(".acpmux-attachment") ?? slot;
    const rect = chip?.getBoundingClientRect();
    if (!rect || !(rect.width > 0) || !(rect.height > 0)) continue;
    origins.set(attachment.id, { rect, at: now });
    if (attachment.path) origins.set(`path:${attachment.path}`, { rect, at: now });
  }
}

/// The chip place noted for `key` (an attachment id, or `path:` and a video's path), once.
export function takeSendOrigin(key: string, now = performance.now()): DOMRect | undefined {
  const origin = origins.get(key);
  origins.delete(key);
  return origin && now - origin.at <= ORIGIN_MS ? origin.rect : undefined;
}

/// The transform that draws a box laid out at `to` over `from` (top-left origin), per style.
export function morphFrom(from: DOMRect, to: DOMRect, style: SendMorphStyle): string | undefined {
  if (style === "fade" || !(to.width > 0) || !(to.height > 0)) return undefined;
  const sx = from.width / to.width;
  const sy = from.height / to.height;
  if (style === "grow") {
    // In its slot, from the chip's size, around its own center.
    const dx = (to.width - from.width) / 2;
    const dy = (to.height - from.height) / 2;
    return `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})`;
  }
  return `translate(${from.left - to.left}px, ${from.top - to.top}px) scale(${sx}, ${sy})`;
}

/// The host's entrance token (`--agent-motion-in`), 0 when motion is off for this page.
function motionMs(element: Element): number {
  const doc = element.ownerDocument;
  if (!entranceAllowed(doc)) return 0;
  if (doc.defaultView?.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return 0;
  const token = getComputedStyle(doc.documentElement).getPropertyValue("--agent-motion-in").trim();
  const value = Number.parseFloat(token);
  if (!token || !Number.isFinite(value)) return MOTION_MS.standard;
  return token.endsWith("ms") ? value : value * 1000;
}

/// A ref for a sent preview's box: on mount, if the composer noted a chip for `key`, the box draws
/// its first frame over the chip and moves to where it is laid out. Once per send; a remount (the
/// virtual transcript scrolling it back, acpmux's echo naming the image by its bytes) finds no
/// origin and draws in place.
export function sendMorphRef(key: string | undefined): (element: HTMLElement | null) => void {
  return (element) => {
    if (!element || key === undefined) return;
    const from = takeSendOrigin(key);
    if (!from || typeof element.animate !== "function") return;
    const style = (element.closest("[data-send-morph]")?.getAttribute("data-send-morph") ?? "move") as SendMorphStyle;
    const duration = motionMs(element);
    if (!(duration > 0) || style === "fade") return;
    // The chip does not fade or slide in: it moves, at full ink, so its row's entrance (its fade,
    // its 4px rise, the thumbnail's own fade) ends at once around it, before the slot is read.
    if (style === "move") finishEntrances(element);
    const transform = morphFrom(from, element.getBoundingClientRect(), style);
    if (!transform) return;
    element.animate(
      [
        { transform, transformOrigin: "0 0" },
        { transform: "none", transformOrigin: "0 0" },
      ],
      {
        duration,
        easing:
          getComputedStyle(element.ownerDocument.documentElement).getPropertyValue("--agent-ease-out").trim() ||
          "ease-out",
      },
    );
  };
}

/// Ends the entrance animations of `element` and of each box around it up to its transcript row
/// (its prompt's box outside a transcript), never past it.
function finishEntrances(element: HTMLElement): void {
  const row = element.closest(".acpmux-row") ?? element.closest(".cv-user");
  for (let at: Element | null = element; at; at = at.parentElement) {
    for (const animation of at.getAnimations()) animation.finish();
    if (at === row || !row) return;
  }
}

/// Forgets every noted chip (tests).
export function clearSendOrigins(): void {
  origins.clear();
}

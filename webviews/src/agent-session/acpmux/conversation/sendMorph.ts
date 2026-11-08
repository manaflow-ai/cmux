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
import { motionMode } from "../../../ui/motion/motionMode";

/// How the sent preview comes in: `move` (the product's) goes from the chip's place and size to its
/// slot; `grow` scales up from the chip's size in its slot; `fade` is the row's own fade only. The
/// gallery compares them (SendTransition.gallery.tsx) through `data-send-morph` on an ancestor.
export type SendMorphStyle = "move" | "grow" | "fade";

type Origin = { rect: DOMRect; at: number };

/// A chip's place is used only by a sent row drawn soon after the send; later it is stale.
const ORIGIN_MS = 2000;
/// Chips' places by attachment id and, for a video, by its path (a sent video tile knows only that).
const origins = new Map<string, Origin>();

/// The composer's chips on screen by attachment id: the strip's slot and a chip placed in the text
/// register here (`chipRef`; attachmentIntake.tsx, inlineAttachments.tsx).
const chips = new Map<string, Element>();

/// A ref for the box that holds attachment `id`'s chip in the composer.
export function chipRef(id: string): (element: Element | null) => void {
  let held: Element | null = null;
  return (element) => {
    if (element) chips.set(id, (held = element));
    else if (held && chips.get(id) === held) chips.delete(id);
    if (!element) held = null;
  };
}

/// Records where each of `attachments`' chips is in the composer, before the composer lets them go.
/// O(sent attachments).
export function noteSendOrigins(attachments: readonly { id: string; path?: string }[], now = performance.now()): void {
  for (const [key, origin] of origins) if (now - origin.at > ORIGIN_MS) origins.delete(key);
  for (const attachment of attachments) {
    const slot = chips.get(attachment.id);
    if (!slot?.isConnected) continue;
    // The strip's slot draws nothing of its own (display: contents): its chip has the box.
    const rect = (slot.querySelector(".acpmux-attachment") ?? slot).getBoundingClientRect();
    if (!(rect.width > 0) || !(rect.height > 0)) continue;
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

/// The transform, `progress` of the way (0 to 1), that draws a box of `to`'s size, placed at the
/// viewport's origin, from `from` to `to`, per style: `move` goes from the chip's place and size,
/// `grow` stays centered on its slot and scales up from the chip's size.
export function morphAt(from: DOMRect, to: DOMRect, style: SendMorphStyle, progress: number): string | undefined {
  if (style === "fade" || !(to.width > 0) || !(to.height > 0)) return undefined;
  const width = from.width + (to.width - from.width) * progress;
  const height = from.height + (to.height - from.height) * progress;
  const left = style === "grow" ? to.left + (to.width - width) / 2 : from.left + (to.left - from.left) * progress;
  const top = style === "grow" ? to.top + (to.height - height) / 2 : from.top + (to.top - from.top) * progress;
  return `translate(${left}px, ${top}px) scale(${width / to.width}, ${height / to.height})`;
}

/// The host's entrance token (`--agent-motion-in`), 0 when motion is off for this page: the shared
/// gate (ui/motion/motionMode.ts: `data-agent-motion`, `data-cmux-motion`, a zero token, Reduce
/// Motion, a hidden page) and a page whose first frame back has not passed (entranceAllowed).
function motionMs(element: Element): number {
  const doc = element.ownerDocument;
  if (motionMode(doc) !== "full" || !entranceAllowed(doc)) return 0;
  const token = getComputedStyle(doc.documentElement).getPropertyValue("--agent-motion-in").trim();
  const value = Number.parseFloat(token);
  if (!token || !Number.isFinite(value)) return MOTION_MS.standard;
  return token.endsWith("ms") ? value : value * 1000;
}

/// A ref for a sent preview's box: on mount, if the composer noted a chip for `key`, the preview
/// draws its first frame over the chip and moves to where it is laid out. The transcript's scroller
/// and its rows clip their paint (`overflow`, `contain: paint`; styles.css), and the composer is
/// outside them, so the move is drawn by a copy of the preview fixed over the pane, the slot itself
/// held empty under it until it lands. Once per send; a remount (the virtual transcript scrolling it
/// back, acpmux's echo naming the image by its bytes) finds no origin and draws in place.
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
    // A sent image that names its source wears the badge on a box around it (UserBubble.tsx
    // `.cv-user__sourced`, the thumbnail's own size): that box moves, so the badge goes with it.
    const sourced = element.parentElement?.closest(".cv-user__sourced, .cv-user__bubble");
    const moved = sourced?.matches(".cv-user__sourced") ? (sourced as HTMLElement) : element;
    const to = moved.getBoundingClientRect();
    const transform = morphAt(from, to, style, 0);
    if (!transform) return;
    const doc = element.ownerDocument;
    const view = doc.defaultView;
    if (!view) return;
    const layer = element.closest(".acpmux-shell") ?? doc.body;
    // The copy sits in the same box the preview's own rules style (conversation.css
    // .cv-user__inline-image: its corners, outline, backing, a poster's cover, a button's reset), so
    // it looks the same in flight as before and after it.
    const ghost = doc.createElement("span");
    ghost.className = "cv-user__inline-image";
    ghost.setAttribute("aria-hidden", "true");
    ghost.setAttribute("data-send-morph-ghost", "");
    const copy = moved.cloneNode(true) as HTMLElement;
    copy.removeAttribute("id");
    copy.classList.remove("cv-enter");
    ghost.appendChild(copy);
    Object.assign(ghost.style, {
      position: "fixed",
      left: "0",
      top: "0",
      width: `${to.width}px`,
      height: `${to.height}px`,
      maxWidth: "none",
      margin: "0",
      display: "block",
      zIndex: "var(--layer-overlay)",
      pointerEvents: "none",
      transformOrigin: "0 0",
      transform,
    });
    layer.appendChild(ghost);
    const held = moved.style.visibility;
    moved.style.visibility = "hidden";
    // The move's clock and easing (the host's ease-out token); each frame reads where the slot is
    // then, so a transcript that scrolls or glides to the new prompt is followed, not overshot.
    const clock = ghost.animate([], {
      duration,
      easing: getComputedStyle(doc.documentElement).getPropertyValue("--agent-ease-out").trim() || "ease-out",
    });
    let frame = 0;
    const land = () => {
      view.cancelAnimationFrame(frame);
      ghost.remove();
      moved.style.visibility = held;
    };
    // Stops when the preview leaves the page, the clock is cancelled (land), or once the copy has
    // drawn one frame at the slot after the clock ended: the preview then shows where the copy was.
    let ended = false;
    const step = () => {
      if (!moved.isConnected || ended) return land();
      ended = clock.playState === "finished";
      const progress = ended ? 1 : (clock.effect?.getComputedTiming().progress ?? 1);
      const now = morphAt(from, moved.getBoundingClientRect(), style, progress);
      if (now) ghost.style.transform = now;
      frame = view.requestAnimationFrame(step);
    };
    frame = view.requestAnimationFrame(step);
    clock.oncancel = land;
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
  chips.clear();
}

// A prompt sent while the transcript is scrolled up (Leo, 2026-11-08, ask-157340f908): "if you're not
// at the bottom ... there's a little animation where it appears to jump over your composer and then
// tuck under it ... it kind of, like, waterfalls over the composer if you think of the composer as a
// bar, that they go, like, over and then under behind." The composer clears at once (Composer.tsx
// `send`), and a small copy of what went (its text as a pill, its chips' thumbnails) rises from where
// it was typed over the composer's top edge and drops behind the bar, on the send clock
// (`--agent-motion-send`). The transcript has the prompt at its latest row when the reader goes
// down there; nothing flies through the rows they are reading.
//
// Two copies draw it, each with one Web Animation on the same clock, in two layers over the pane
// (over the composer and the transcript's floating controls): one whole (the rise, out of the
// composer), one in a layer whose box ends at the composer's top edge (the fall: what passes the
// edge is cut off there, so it goes behind the bar, and a translucent card never shows it through).
// They swap at the arc's apex, where the copy is above the edge and both draw the same. Transform
// and opacity only; the layers are removed when the clock ends, is cancelled, or the page goes
// away. With motion off (the host's switch, Reduce Motion, a hidden page or one whose first frame
// back has not passed) nothing is drawn: the composer just clears.
import { MOTION_SEND_MS } from "../../../motion/scale.generated";
import { motionMode } from "../../../ui/motion/motionMode";
import { entranceAllowed } from "../../shared/pageReveal";
import { cssTimeMs } from "./fold";
import { INLINE_TOKEN } from "../attachments";

/// How the copy goes (the gallery compares them through `data-send-tuck` on an ancestor,
/// SendTuck.gallery.tsx): `arc` (the product's) rises on a short arc drifting toward the sent
/// prompts' side and drops behind the bar; `funnel` narrows toward a point on the edge as it goes
/// under, a small genie squeeze; `drop` lifts straight up and slides straight under; `none` draws
/// nothing (the composer just clears, as before).
export type SendTuckStyle = "arc" | "funnel" | "drop" | "none";
export const SEND_TUCK_STYLES: readonly SendTuckStyle[] = ["arc", "funnel", "drop", "none"];
const DEFAULT_STYLE: SendTuckStyle = "arc";

/// Where the transcript was when the prompt went: at its latest row (`following`), and whether the
/// send then glides the view there (`ridesToLatest`, sendScrollSetting.ts).
export type SendPlace = { following: boolean; ridesToLatest: boolean };

/// Whether this send tucks. Open question (ask-157340f908): Leo's words read as if a scrolled-up
/// view stays where it is, but by default a scrolled-up send still glides to the latest row
/// (`shouldScrollToBottomAfterSend`). Until that is answered, any send made away from the latest row
/// tucks, whether or not the view then rides; `&& !place.ridesToLatest` is the one-line change if
/// only a kept view should.
export function sendTucks(place: SendPlace): boolean {
  return !place.following;
}

/// How far the copy's bottom clears the composer's top edge at the apex (px).
const LIFT = 14;
/// How far it drifts toward the side the sent prompts are drawn on (px).
const DRIFT = 28;
/// Thumbnails of at most this many chips go with the pill.
const MAX_CHIPS = 3;

/// The tuck now drawing, if any: a new send ends it first.
let running: (() => void) | undefined;

/// The copy that tucks away, taken at the send: the composer may hold the next draft by the time a
/// send the host takes later clears it.
export function tuckContent(box: HTMLElement | null | undefined, text: string): HTMLElement | undefined {
  if (!box?.isConnected) return undefined;
  return ghostOf(box.ownerDocument, box, text);
}

/// Draws the tuck of a prompt sent from the composer `box` (`.acpmux-composer-box`), with `sent` its
/// copy (`tuckContent`, taken at the send while its chips were still drawn). Draws nothing when
/// motion is off, when the composer is not in a pane, or for `none`.
export function tuckSent(box: HTMLElement | null | undefined, sent: HTMLElement | undefined): void {
  running?.();
  if (!box?.isConnected || !sent) return;
  const doc = box.ownerDocument;
  const view = doc.defaultView;
  const main = box.closest<HTMLElement>(".acpmux-main");
  const editor = box.querySelector<HTMLElement>(".acpmux-composer-prompt [contenteditable]");
  if (!view || !main || !editor) return;
  const style = tuckStyle(box);
  if (style === "none" || motionMode(doc) !== "full" || !entranceAllowed(doc)) return;
  const duration = sendMs(box);
  if (!(duration > 0)) return;
  const ghost = sent;

  const mainBox = main.getBoundingClientRect();
  const edge = box.getBoundingClientRect().top - mainBox.top;
  const field = editor.getBoundingClientRect();
  const over = layer(doc, "over");
  const under = layer(doc, "under");
  // The falling copy's layer ends at the composer's top edge: what falls past it is gone.
  under.style.height = `${Math.max(0, edge)}px`;
  under.style.overflow = "hidden";
  main.append(under, over);
  const left = field.left - mainBox.left;
  const top = field.top - mainBox.top;
  const lower = ghost.cloneNode(true) as HTMLElement;
  ghost.setAttribute("data-send-tuck-ghost", "over");
  lower.setAttribute("data-send-tuck-ghost", "under");
  for (const copy of [ghost, lower]) {
    copy.style.left = `${left}px`;
    copy.style.top = `${top}px`;
  }
  over.appendChild(ghost);
  under.appendChild(lower);
  // One layout read for the pill's size, before any animation starts.
  const height = ghost.getBoundingClientRect().height;
  const room = Math.max(0, mainBox.width - (field.left - mainBox.left) - ghost.getBoundingClientRect().width - 8);
  const path = tuckPath(style, {
    rise: Math.max(0, top + height - edge) + LIFT,
    drop: Math.max(0, edge - top) + 2,
    drift: Math.min(DRIFT, room),
  });
  const timing: KeyframeAnimationOptions = { duration, easing: "linear", fill: "both" };
  const upper = ghost.animate(
    path.frames.map((frame, index) => ({ ...frame, opacity: index <= path.apex ? 1 : 0 })),
    timing,
  );
  const fall = lower.animate(
    path.frames.map((frame, index) => ({ ...frame, opacity: index <= path.apex ? 0 : 1 })),
    timing,
  );
  // The composer clears in the same frame and gives back the height its text and chips took, so its
  // top edge moves down: the copies and the edge move with it, before that frame paints (a resize
  // observer runs after layout and before paint), so the copy starts where the text was in the
  // composer and falls behind the edge where it is now.
  const placed = edge;
  const moved =
    typeof ResizeObserver === "function"
      ? new ResizeObserver(() => {
          const now = box.getBoundingClientRect().top - main.getBoundingClientRect().top;
          under.style.height = `${Math.max(0, now)}px`;
          for (const copy of [ghost, lower]) copy.style.top = `${top + now - placed}px`;
        })
      : undefined;
  moved?.observe(box);
  const away = () => {
    if (doc.visibilityState === "hidden") end();
  };
  // Stops on the clock's end or cancel, or when the page goes away; every path removes both layers.
  const end = () => {
    if (running !== end) return;
    running = undefined;
    moved?.disconnect();
    doc.removeEventListener("visibilitychange", away);
    view.removeEventListener("pagehide", end);
    upper.cancel();
    fall.cancel();
    over.remove();
    under.remove();
  };
  running = end;
  doc.addEventListener("visibilitychange", away);
  view.addEventListener("pagehide", end);
  fall.onfinish = end;
  fall.oncancel = end;
  upper.oncancel = end;
}

type Frame = { offset: number; transform: string; easing?: string };

/// The copy's way per style, as keyframes from where it was typed: `rise` (px up) takes its bottom
/// over the edge, `drop` (px down) takes its top under it, `drift` (px right) toward the sent
/// prompts' side. `apex`: the index of the last frame drawn over the composer; the copy under it
/// draws from the next one, at the same offset and place.
export function tuckPath(
  style: Exclude<SendTuckStyle, "none">,
  { rise, drop, drift }: { rise: number; drop: number; drift: number },
): { frames: Frame[]; apex: number } {
  // Up fast and settling at the top, then down as if falling.
  const up = "cubic-bezier(0.2, 0.8, 0.4, 1)";
  const down = "cubic-bezier(0.55, 0, 0.85, 0.35)";
  const at = (x: number, y: number, sx = 1, sy = sx) => `translate(${x}px, ${y}px) scale(${sx}, ${sy})`;
  if (style === "funnel") {
    const top = at(drift * 0.4, -rise, 0.96);
    return {
      apex: 1,
      frames: [
        { offset: 0, transform: at(0, 0), easing: up },
        { offset: 0.38, transform: top },
        { offset: 0.38, transform: top, easing: down },
        // Halfway through the edge, narrowing toward the point it goes under at.
        { offset: 0.72, transform: at(drift * 0.8, (drop - 2 - (rise - LIFT)) / 2, 0.5, 0.92), easing: down },
        { offset: 1, transform: at(drift, drop, 0.12, 0.7) },
      ],
    };
  }
  if (style === "drop") {
    const top = at(0, -rise);
    return {
      apex: 1,
      frames: [
        { offset: 0, transform: at(0, 0), easing: up },
        { offset: 0.35, transform: top },
        { offset: 0.35, transform: top, easing: down },
        { offset: 1, transform: at(0, drop) },
      ],
    };
  }
  const top = at(drift * 0.45, -rise, 0.94);
  return {
    apex: 1,
    frames: [
      { offset: 0, transform: at(0, 0), easing: up },
      { offset: 0.42, transform: top },
      { offset: 0.42, transform: top, easing: down },
      { offset: 1, transform: at(drift, drop, 0.86) },
    ],
  };
}

/// The style an ancestor asks for (`data-send-tuck`), else the product's.
function tuckStyle(box: Element): SendTuckStyle {
  const asked = box.closest("[data-send-tuck]")?.getAttribute("data-send-tuck");
  return SEND_TUCK_STYLES.includes(asked as SendTuckStyle) ? (asked as SendTuckStyle) : DEFAULT_STYLE;
}

/// The send clock (`--agent-motion-send`, scaled with the host's speed), the scale's value without one.
function sendMs(box: Element): number {
  const token = box.ownerDocument.defaultView?.getComputedStyle(box).getPropertyValue("--agent-motion-send") ?? "";
  return cssTimeMs(token) ?? MOTION_SEND_MS;
}

/// A layer over the pane for one half of the tuck: it takes no pointer and draws nothing itself.
function layer(doc: Document, half: "over" | "under"): HTMLElement {
  const element = doc.createElement("div");
  element.className = "acpmux-send-tuck-layer";
  element.setAttribute("data-send-tuck-layer", half);
  element.setAttribute("aria-hidden", "true");
  return element;
}

/// The copy of what was sent: up to three chips' thumbnails (an image's picture, another chip's
/// name) and the text's first line as a small pill. Undefined when there is nothing to draw.
function ghostOf(doc: Document, box: HTMLElement, text: string): HTMLElement | undefined {
  const ghost = doc.createElement("div");
  ghost.className = "acpmux-send-tuck";
  const form = box.closest(".acpmux-composer") ?? box;
  for (const chip of [...form.querySelectorAll(".acpmux-attachment")].slice(0, MAX_CHIPS)) {
    const image = chip.querySelector("img");
    if (image?.currentSrc || image?.src) {
      const thumb = doc.createElement("img");
      thumb.className = "acpmux-send-tuck__thumb";
      thumb.alt = "";
      thumb.src = image.currentSrc || image.src;
      ghost.appendChild(thumb);
    } else {
      const name = chip.textContent?.trim();
      if (!name) continue;
      const label = doc.createElement("span");
      label.className = "acpmux-send-tuck__pill acpmux-send-tuck__pill--chip";
      label.textContent = name;
      ghost.appendChild(label);
    }
  }
  // The field's own words when it has one, even none (an image-only prompt); else the sent text
  // without the places its attachments hold (attachments.ts INLINE_TOKEN).
  const line = (shownText(box) ?? text.replace(INLINE_TOKEN, "")).trim().split("\n", 1)[0]?.trim();
  if (line) {
    const pill = doc.createElement("span");
    pill.className = "acpmux-send-tuck__pill";
    pill.textContent = line;
    ghost.appendChild(pill);
  }
  return ghost.childElementCount > 0 ? ghost : undefined;
}

/// The words the composer's field shows, without its chips: the sent text carries an attachment's
/// place as its id, which the pill does not show.
function shownText(box: HTMLElement): string | undefined {
  const field = box.querySelector(".acpmux-composer-prompt [contenteditable]");
  if (!field) return undefined;
  const copy = field.cloneNode(true) as Element;
  for (const chip of copy.querySelectorAll('[contenteditable="false"], .acpmux-md-inline-chip, .acpmux-attachment'))
    chip.remove();
  return (copy.textContent ?? "").replace(/[^\S\n]+/g, " ").trim();
}

/// Ends a tuck still drawing (tests).
export function endSendTuck(): void {
  running?.();
}

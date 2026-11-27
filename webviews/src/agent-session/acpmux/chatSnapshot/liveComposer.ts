// The live composer shows through the chat's copy as soon as it is the composer the copy drew. Leo,
// 2026-11-22: "if it means a composer that's TECHNICALLY not wholly interactive as in it'd send data
// but you can click around on it and type in it, that's enough. that's the "functionali-ish
// skeleton" we want to aim for".
//
// The copy (paint.ts) covers the whole page until the live page drew the chat, and until then a press
// or a key ended it (live.ts). The composer is mounted long before the transcript is read, so here the
// copy gets a hole the shape of the composer's box and the live box shows in it: the same pixels, but
// it takes the caret, the typing and the clicks, while the transcript above stays the copy. Only when
// the live box sits where the copy's does and says the same words, so nothing the person sees moves or
// changes as it happens; otherwise nothing is done and the copy stays whole, as before.
import { SNAPSHOT_HOST_TAG, SNAPSHOT_SHOWN_GLOBAL } from "./shared";

const BOX = ".acpmux-composer .acpmux-composer-box";
const EDITOR = '[contenteditable]:not([contenteditable="false"]), textarea';
/// How far the live box may sit from the copy's and still be the same box (subpixel layout).
const FIT_PX = 1;
/// The keys that edit text with Cmd or Ctrl held: they stay the editor's while the copy shows.
const EDIT_KEYS = new Set([
  "a",
  "c",
  "v",
  "x",
  "z",
  "y",
  "backspace",
  "delete",
  "arrowleft",
  "arrowright",
  "arrowup",
  "arrowdown",
]);

type Carved = { doc: Document; box: HTMLElement; host: HTMLElement; copy: HTMLElement };
let carved: Carved | undefined;
/// The copies whose hole showed once: the person may have typed in the live box since, so its draft
/// is no longer the copy's and only what is around the editor is compared again.
const shownIn = new WeakSet<HTMLElement>();

function words(element: Element): string {
  return (element.textContent ?? "").replace(/\s+/g, " ").trim();
}

/// The box's words outside its editor: the chips and buttons, which the person does not type.
function around(box: Element): string {
  let text = "";
  const walk = (node: Node) => {
    if (node.nodeType === 3) text += node.nodeValue ?? "";
    else if (node.nodeType === 1 && !(node as Element).matches(EDITOR)) node.childNodes.forEach(walk);
  };
  walk(box);
  return text.replace(/\s+/g, " ").trim();
}

/// Whether the live box still draws what the copy drew around the editor, where the copy drew it.
function stillSame(target: Carved): boolean {
  const at = target.box.getBoundingClientRect();
  const was = target.copy.getBoundingClientRect();
  return (
    Math.abs(at.left - was.left) <= FIT_PX &&
    Math.abs(at.width - was.width) <= FIT_PX &&
    Math.abs(at.bottom - was.bottom) <= FIT_PX &&
    around(target.box) === around(target.copy)
  );
}

function near(a: DOMRect, b: DOMRect): boolean {
  return (
    Math.abs(a.left - b.left) <= FIT_PX &&
    Math.abs(a.top - b.top) <= FIT_PX &&
    Math.abs(a.width - b.width) <= FIT_PX &&
    Math.abs(a.height - b.height) <= FIT_PX
  );
}

/// The copy's clip: everything but a rounded hole over `rect`.
function holeOver(rect: DOMRect, radius: number): string {
  const r = Math.max(0, Math.min(radius, rect.width / 2, rect.height / 2));
  const { left: l, top: t, right: e, bottom: b } = rect;
  const arc = `A${r} ${r} 0 0 1`;
  const inner = `M${l + r} ${t}H${e - r}${arc} ${e} ${t + r}V${b - r}${arc} ${e - r} ${b}H${l + r}${arc} ${l} ${b - r}V${t + r}${arc} ${l + r} ${t}Z`;
  return `path(evenodd, "M-100000 -100000H100000V100000H-100000Z${inner}")`;
}

function cut(target: Carved): void {
  const view = target.doc.defaultView;
  if (!view) return;
  const radius = Number.parseFloat(view.getComputedStyle(target.box).borderTopLeftRadius) || 0;
  target.host.style.clipPath = holeOver(target.box.getBoundingClientRect(), radius);
}

/// Whether the live composer shows through the copy now.
export function showsLiveComposer(): boolean {
  return !!carved && carved.box.isConnected && carved.host.isConnected;
}

/// Shows the live composer's box through the copy when it is the box the copy drew (same place, same
/// words, with an editor in it); keeps the hole over it while what is around the editor stays what the
/// copy drew (a chip the live page drops, or a box that moves, puts the copy back whole in the same
/// frame, so nothing the copy showed goes). True while it shows.
export function fitLiveComposer(doc: Document = document): boolean {
  if (carved && (!showsLiveComposer() || !stillSame(carved))) undoLiveComposer();
  if (carved) {
    cut(carved);
    return true;
  }
  const view = doc.defaultView;
  const host = doc.querySelector<HTMLElement>(SNAPSHOT_HOST_TAG);
  const root = doc.getElementById("root");
  const copy = host?.shadowRoot?.querySelector<HTMLElement>(BOX);
  const box = root?.querySelector<HTMLElement>(BOX);
  if (!view || !host || !root || !copy || !box || !box.querySelector(EDITOR)) return false;
  // The copy is laid out hidden until its sheets load (paint.ts): no hole in a copy that does not show.
  if (host.style.visibility === "hidden") return false;
  const at = box.getBoundingClientRect();
  if (at.width <= 0 || at.height <= 0) return false;
  const fresh = { doc, box, host, copy };
  // The first time, the whole box is the copy's, draft and all. After it showed once, the draft is
  // the person's and the box grows upward with it: the rest must still be the copy's.
  if (shownIn.has(host) ? !stillSame(fresh) : !near(at, copy.getBoundingClientRect()) || words(box) !== words(copy))
    return false;
  carved = fresh;
  shownIn.add(host);
  // The live root is under the copy at opacity 0 (paint.ts), which hides the box with it: hidden by
  // `visibility` instead, the box alone shows, and what is around it stays unseen under the copy.
  root.style.removeProperty("opacity");
  root.style.visibility = "hidden";
  box.style.visibility = "visible";
  cut(carved);
  const shown = (view as unknown as Record<string, unknown>)[SNAPSHOT_SHOWN_GLOBAL] as
    | { composerAt?: number }
    | undefined;
  if (shown && shown.composerAt === undefined) shown.composerAt = view.performance.now();
  view.performance.mark?.("cmux-chat:composer-live");
  return true;
}

/// The page as it was before the hole: the copy whole (if it still shows), the live root as paint.ts
/// left it. Called as the copy goes, in the task that removes it, so one frame shows the live page.
export function undoLiveComposer(): void {
  const was = carved;
  carved = undefined;
  if (!was) return;
  was.box.style.removeProperty("visibility");
  was.host.style.removeProperty("clip-path");
  const root = was.doc.getElementById("root");
  if (!root) return;
  root.style.removeProperty("visibility");
  if (was.host.isConnected) root.style.opacity = "0";
}

/// What a press or key does while the live composer shows through the copy. `keep`: it is the
/// composer's own (a click or typing in its editor) and the copy stays. `reveal`: it is on another of
/// the composer's controls, which may open something outside the box, so the copy goes and the press
/// acts. Nothing: it is not the composer's, and the copy's own rule applies (live.ts).
export function liveComposerTakes(event: Event): "keep" | "reveal" | undefined {
  if (!showsLiveComposer() || !carved) return undefined;
  const { box, doc } = carved;
  if (event.type === "pointerdown") {
    const target = event.target;
    if (!(target instanceof box.ownerDocument.defaultView!.Node) || !box.contains(target)) return undefined;
    const element = target instanceof box.ownerDocument.defaultView!.Element ? target : target.parentElement;
    return element?.closest(EDITOR) ? "keep" : "reveal";
  }
  if (event.type === "keydown") {
    const focused = doc.activeElement;
    if (!focused || !box.contains(focused) || !focused.closest(EDITOR)) return undefined;
    const key = event as KeyboardEvent;
    if ((key.metaKey || key.ctrlKey) && !EDIT_KEYS.has(key.key.toLowerCase())) return undefined;
    return "keep";
  }
  return undefined;
}

/// Watches the live page for its composer while the copy shows, one check a frame the page changed
/// in. Returns the stop, which also takes the hole back.
export function watchLiveComposer(doc: Document = document): () => void {
  const view = doc.defaultView;
  const root = doc.getElementById("root");
  if (!view || !root || !view.CSS?.supports?.("clip-path", 'path(evenodd, "M0 0H1V1Z")')) return () => {};
  let frame: number | undefined;
  let stopped = false;
  const check = () => {
    frame = undefined;
    if (!stopped) fitLiveComposer(doc);
  };
  const ask = () => {
    if (frame === undefined && !stopped) frame = view.requestAnimationFrame(check);
  };
  // A change that makes the live box other than the copy's closes the hole here, before the frame
  // that would have shown it; the fit itself waits for the frame (it reads layout).
  const observer = new view.MutationObserver(() => {
    if (carved && around(carved.box) !== around(carved.copy)) undoLiveComposer();
    ask();
  });
  observer.observe(root, { subtree: true, childList: true, characterData: true });
  view.addEventListener("resize", ask);
  ask();
  return () => {
    if (stopped) return;
    stopped = true;
    observer.disconnect();
    view.removeEventListener("resize", ask);
    if (frame !== undefined) view.cancelAnimationFrame(frame);
    undoLiveComposer();
  };
}

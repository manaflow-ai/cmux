// Where an opened line of a row's tool calls is on screen before the row's folds regroup, and the
// ask to keep it there after (KeepOpenedLine.tsx). A new call can put a group's line over a call the
// reader opened ("Ran 2 commands" over the lone command it joins) or turn a group into a run: the call
// they were reading would move down by a line under them (Leo, 2026-11-08: "if i have a tool call
// expanded, the auto folding situation shouldn't collapse it when a new tool call comes in and the
// folds reformat").
import { ANCHORED_COLLAPSE_EVENT } from "./foldAnchor";

/// An opened line: a call's own (`data-tool-id`), a group's (`data-tool-group`) or a run's
/// (`data-tool-run`). Each is keyed by an id that outlasts the regroup, so the line is found again.
const OPENED = [
  'button[aria-expanded="true"][data-tool-id]',
  'button[aria-expanded="true"][data-tool-group]',
  'button[aria-expanded="true"][data-tool-run]',
].join(", ");
const ATTRIBUTES = ["data-tool-id", "data-tool-group", "data-tool-run"] as const;

export type OpenedLine = { selector: string; top: number };

/// What a regroup hold asks the transcript for (VirtualTranscript.tsx `holdAsked`): keep the line at
/// `top`, where it was drawn before the regroup, not where the regroup drew it.
export type RegroupHold = { regroup: true; top: number };

export function isRegroupHold(detail: unknown): detail is RegroupHold {
  return (
    typeof detail === "object" &&
    detail !== null &&
    (detail as RegroupHold).regroup === true &&
    typeof (detail as RegroupHold).top === "number"
  );
}

function scrollerOf(node: HTMLElement): HTMLElement | undefined {
  const transcript = node.closest<HTMLElement>(".acpmux-scroll");
  if (transcript) return transcript;
  const view = node.ownerDocument.defaultView;
  for (let at = node.parentElement; at; at = at.parentElement) {
    const overflow = view?.getComputedStyle(at).overflowY;
    if ((overflow === "auto" || overflow === "scroll") && at.scrollHeight > at.clientHeight) return at;
  }
  return node.ownerDocument.scrollingElement as HTMLElement | undefined;
}

/// The first opened line of `box` the reader can see, and its top; none when no opened line is in
/// view. A line above the view's top or under its foot is none: a regroup there moves the row the
/// reader is not looking at, never the text they are reading (holding it would scroll that text).
/// Reads only the row's own lines.
export function openedLineAt(box: HTMLElement | null): OpenedLine | undefined {
  if (!box) return undefined;
  const lines = box.querySelectorAll<HTMLElement>(OPENED);
  if (!lines.length) return undefined;
  const scroller = scrollerOf(box);
  const page = !scroller || scroller === box.ownerDocument.scrollingElement;
  const view = page ? undefined : scroller.getBoundingClientRect();
  const viewTop = view?.top ?? 0;
  const viewBottom = view?.bottom ?? box.ownerDocument.defaultView?.innerHeight ?? 0;
  for (const line of lines) {
    const rect = line.getBoundingClientRect();
    if (rect.bottom <= viewTop) continue;
    if (rect.top >= viewBottom) return undefined;
    const attribute = ATTRIBUTES.find((name) => line.hasAttribute(name))!;
    const value = line.getAttribute(attribute)!.replace(/["\\]/g, "\\$&");
    return { selector: `button[${attribute}="${value}"]`, top: rect.top };
  }
  return undefined;
}

/// After the regroup: the same line found again and held where it was. The transcript (which answers
/// the event) holds it through its placement passes; anywhere else the nearest scroller moves by it.
export function keepOpenedLine(box: HTMLElement | null, line: OpenedLine): void {
  const node = box?.querySelector<HTMLElement>(line.selector);
  if (!node) return;
  const moved = node.getBoundingClientRect().top - line.top;
  if (Math.abs(moved) < 0.5) return;
  const Custom = node.ownerDocument.defaultView?.CustomEvent ?? CustomEvent;
  const detail: RegroupHold = { regroup: true, top: line.top };
  const answered = !node.dispatchEvent(
    new Custom(ANCHORED_COLLAPSE_EVENT, { bubbles: true, cancelable: true, detail }),
  );
  if (answered) return;
  const scroller = scrollerOf(node);
  if (scroller) scroller.scrollTop += moved;
}

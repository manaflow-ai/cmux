import { LayeredMap } from "../conversation/layeredMap";

/// A row's height as the page drew it at a width. It places the row until its next version is drawn.
/// `actions`: whether a reply kept its action row's room then (model.ts `keepsReplyRoom`); a drawn
/// height taken without it, or with it, is stale once the row after the reply changes that.
export type DrawnHeight = {
  sessionId?: string;
  version: number;
  width: number;
  height: number;
  actions?: boolean;
  /// model.ts `statusEdge` when it was drawn: the room under the row depends on it.
  status?: string;
  /// Whether the row was collapsing to nothing then (it holds `[data-row-collapsing]`): its gaps
  /// shrink with it (model.ts `collapsingHeight`).
  collapsing?: true;
};

/// `height` is undefined for a row the page has not laid out (drawnHeightOf).
export type ReportDrawn = (
  id: string,
  version: number,
  height: number | undefined,
  actions?: boolean,
  status?: string,
  collapsing?: boolean,
) => void;

/// Enqueues a row's pre-paint measurement after all sibling content layout effects have written.
/// `versionOnly`: only the row's version changed since its last queue (a streamed token), which the
/// row's ResizeObserver reports if it changed the row's size (queueDrawn).
export type QueueDrawn = (
  node: HTMLElement,
  id: string,
  version: number,
  actions?: boolean,
  status?: string,
  versionOnly?: boolean,
) => () => void;

/// A mounted row's drawn height, or undefined when the page has not laid it out (an undisplayed
/// transcript, or a DOM without layout): such a box has no client rects. A laid-out row that draws
/// nothing (a step of only quiet thoughts, a render update that joined an earlier card, a payload
/// that never came) is 0 high, and is placed at 0. Dropping that 0 as "not laid out" kept the row's
/// estimate, 26px for each of its items, as blank space in the transcript (Leo, 2026-10-21: a
/// screen-tall gap under "Worked for" and under an opened fold's last command).
/// The cleanup of a row whose commit queued no measure.
export const noQueue = () => {};

export function drawnHeightOf(node: HTMLElement): number | undefined {
  const height = node.getBoundingClientRect().height;
  return height > 0 || node.getClientRects().length > 0 ? height : undefined;
}

/// Whether a drawn row is collapsing to nothing (a read "New since you looked" line shrinking on the
/// motion step, SinceDivider.tsx): the layout shrinks its gaps with it (model.ts `collapsingHeight`).
export function collapsingRow(node: HTMLElement): boolean {
  return node.querySelector("[data-row-collapsing]") !== null;
}

/// Each drawn row's height by id (conversation/layeredMap.ts).
export type DrawnHeights = LayeredMap<DrawnHeight>;

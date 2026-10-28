// What a diff tab shows besides its repository and scope, kept while the host discards its hidden
// page (`memoryDiscardInternalPages`): the file at the top of the view and how far
// into it (an `ItemScrollAnchor`, as Chrome's scroll anchoring keeps a node and an offset,
// third_party/blink/renderer/core/layout/scroll_anchor.cc), the files the reader unfolded that open
// folded (large, generated, viewed or all folded), and the options that last for the tab. The host
// asks `cmux.diff.viewState` right before the discard and gives the answer back as the next page's
// `payload.viewState`. The page also saves the same state each time it hides (pageState.ts),
// for a discard whose host cannot ask a frozen page; the host's answer wins when it
// has one. Input a new page would lose (a comment draft, the commit form) is reported when it
// changes (`cmux.diff.input {unsaved}`): the host keeps such a page.
import { useEffect, useRef } from "react";
import type { DiffItem } from "../diff-stream";
import type { DiffViewerOptions } from "../pierre-options";
import type { PageClient } from "../pages/shared/pageClient";
import type { PageStateSession } from "../pages/shared/pageState";
import type { ItemScrollAnchor } from "./item-navigation";
import { useSyncedRef } from "./useSyncedRef";

export const DIFF_VIEW_STATE_OP = "cmux.diff.viewState";
export const DIFF_INPUT_OP = "cmux.diff.input";

/** The options that last for the tab only (App.tsx `setOption` saves the others as prefs). */
export const TAB_OPTION_KEYS = ["collapsed", "hideImports", "loadFullFiles", "richPreview"] as const;
export type DiffTabOptions = Partial<Pick<DiffViewerOptions, (typeof TAB_OPTION_KEYS)[number]>>;

export interface DiffViewState {
  anchor?: ItemScrollAnchor;
  /** Item ids (tree paths) of files the reader unfolded that open folded. */
  expanded: string[];
  options: DiffTabOptions;
}

/** The state of a page that shows `items` with `options`, scrolled to `anchor`. `opensFolded` says
 * whether an item starts folded when it streams in again. */
export function diffViewState(
  items: readonly DiffItem[],
  anchor: ItemScrollAnchor | null,
  options: DiffViewerOptions,
  opensFolded: (item: DiffItem) => boolean,
): DiffViewState {
  const tabOptions: DiffTabOptions = {};
  for (const key of TAB_OPTION_KEYS) tabOptions[key] = options[key];
  return {
    ...(anchor ? { anchor } : {}),
    expanded: items.filter((item) => !item.collapsed && opensFolded(item)).map((item) => item.id),
    options: tabOptions,
  };
}

/** A `viewState` from the host, or null when it is not one. */
export function diffViewStateOf(value: unknown): DiffViewState | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as { anchor?: unknown; expanded?: unknown; options?: unknown };
  const state: DiffViewState = { expanded: [], options: {} };
  const anchor = raw.anchor as Partial<ItemScrollAnchor> | undefined;
  if (anchor && typeof anchor.itemId === "string" && typeof anchor.offset === "number" && anchor.offset >= 0) {
    state.anchor = { itemId: anchor.itemId, offset: anchor.offset };
  }
  if (Array.isArray(raw.expanded)) state.expanded = raw.expanded.filter((id): id is string => typeof id === "string");
  const options = raw.options as Record<string, unknown> | undefined;
  for (const key of TAB_OPTION_KEYS) {
    if (typeof options?.[key] === "boolean") state.options[key] = options[key];
  }
  return state;
}

/** The page name its hide-time saved state carries (pageState.ts). */
export const DIFF_PAGE = "diff";

/** The view to put back: the host's `payload.viewState`, else what this page saved when it hid. */
export function savedDiffView(
  payloadViewState: unknown,
  pageState: PageStateSession | undefined,
): DiffViewState | null {
  return diffViewStateOf(payloadViewState) ?? diffViewStateOf(pageState?.saved?.inputs);
}

/** The saved files to unfold now: those still in the diff and folded. */
export function itemsToUnfold(items: readonly DiffItem[], saved: DiffViewState): string[] {
  const wanted = new Set(saved.expanded);
  return items.filter((item) => item.collapsed && wanted.has(item.id)).map((item) => item.id);
}

/**
 * Answers `cmux.diff.viewState` with `capture()`, tells the host when the page starts or stops
 * holding `unsaved` input, and once every file of the first diff has arrived (`ready`), puts a
 * saved state back: unfolds its files, then scrolls to its anchor.
 */
export function useDiffViewState(args: {
  client: PageClient | null;
  /** The page host's state (`openPageState(page, DIFF_PAGE)`): saves `capture()` on each hide. */
  pageState?: PageStateSession;
  unsaved: boolean;
  saved: DiffViewState | null;
  ready: boolean;
  items: readonly DiffItem[];
  capture: () => DiffViewState;
  unfold: (itemIds: string[]) => void;
  scrollTo: (anchor: ItemScrollAnchor) => void;
}): void {
  const { client, saved, ready, items } = args;
  const capture = useSyncedRef(args.capture);
  const unfold = useSyncedRef(args.unfold);
  const scrollTo = useSyncedRef(args.scrollTo);
  useEffect(() => client?.handle(DIFF_VIEW_STATE_OP, () => capture.current()), [client, capture]);
  const pageState = args.pageState;
  useEffect(() => pageState?.keep(() => capture.current()), [pageState, capture]);
  const unsaved = args.unsaved;
  const reported = useRef(false);
  useEffect(() => {
    if (!client || unsaved === reported.current) return;
    reported.current = unsaved;
    // An older host has no such op; it keeps every page anyway.
    void client.call(DIFF_INPUT_OP, { unsaved }).catch(() => undefined);
  }, [client, unsaved]);
  const restored = useRef(false);
  useEffect(() => {
    if (restored.current || !saved || !ready) return;
    restored.current = true;
    const ids = itemsToUnfold(items, saved);
    if (ids.length > 0) unfold.current(ids);
    const anchor = saved.anchor;
    // The next frame: the unfolded files are laid out, so the anchor's top is where it will stay.
    if (anchor) requestAnimationFrame(() => scrollTo.current(anchor));
  }, [saved, ready, items, unfold, scrollTo]);
}

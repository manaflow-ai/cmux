import { useLayoutEffect, type RefObject } from "react";

// The chat header's layout as named slots (Leo, 2026-11-22: "the icons on the top right have gotten displaced due to
// putting things on a line. this is not how we should do ui. we need to have a proper way to do ui so that when
// anybody wants to adjust or customize things like this, it is done easily properly.").
//
//   [leading][title ............................][accessory ...][trailing]
//
// - `leading`: what starts the row. In the pane's tab row that is the App's tabs, drawn over the header's left part.
// - `title`: the chat's name, its rolling summary and a connection warning (ChatHeaderStatus). It takes only what the
//   other slots leave (header.css `.acpmux-header-status-slot`, flex 1 1 0) and truncates.
// - `accessory`: optional things beside the tools (the live tree pill, presence faces, the tab row's summary or
//   warning, the worktree pill, the pull request chip, the Needs You count). They take only the room the trailing slot
//   leaves (``accessoryRoom``), and each gives way by its own rule when that room is short.
// - `trailing`: the tools (the panel toggle, the Needs You inbox, the quick actions, "..."). Fixed: no accessory moves them, and they are
//   all of the width the pane's tab row is asked for (`need`, header/tabRow.ts). Only their own quick actions fold,
//   by the pane's width alone (useHeaderFold).
//
// Adding an item is one entry in ``HEADER_ITEMS`` and one ``<HeaderItem id>`` (or ``headerItemProps(id)`` on the
// item's own element) where it renders; nothing in it hand-sets flex CSS. test/chat-header-slots-browser.test.ts
// mounts the header with every accessory on and off at every split and holds the trailing slot still.

export type HeaderSlot = "leading" | "title" | "accessory" | "trailing";

/// What an item does when its slot's room is short:
/// - `truncate`: it narrows with an ellipsis down to its `min`, then hides whole;
/// - `collapse`: it folds into "..." (the quick actions, useHeaderFold);
/// - `hide`: whole or not at all.
export type HeaderOverflow = "truncate" | "collapse" | "hide";

export interface HeaderItemSpec {
  readonly slot: HeaderSlot;
  readonly overflow: HeaderOverflow;
  /// Among the accessories, who keeps its room longest: the lowest gives way first.
  readonly priority?: number;
  /// `truncate`: the narrowest it still says something; below it, it hides whole.
  readonly min?: number;
  /// One width while it shows, whatever its text (the tab row's summary: a new summary moves nothing).
  readonly width?: number;
  /// A part of a trailing control (that control's selector) rather than an element of its own: its width is what it
  /// adds to the control, and hidden the control is its plain self (the Needs You count on the inbox button).
  readonly within?: string;
}

/// Every item of the chat header, by slot. The order of the accessories on screen is where they render; their
/// `priority` decides who gives way.
export const HEADER_ITEMS = {
  // title: the status slot under it all (ChatHeaderStatus); in the tab row it sits under the tabs, hidden.
  title: { slot: "title", overflow: "truncate" },
  summary: { slot: "title", overflow: "truncate" },
  status: { slot: "title", overflow: "truncate" },
  // accessory: beside the tools.
  liveTree: { slot: "accessory", overflow: "hide", priority: 10 },
  presence: { slot: "accessory", overflow: "hide", priority: 20 },
  // In the tab row the summary leads the tools at one width, and says nothing worth its place under 160px.
  inlineSummary: { slot: "accessory", overflow: "truncate", priority: 0, width: 300, min: 160 },
  // In the tab row the warning leads the tools (the title slot is under the tabs).
  inlineStatus: { slot: "accessory", overflow: "truncate", priority: 60, min: 48 },
  worktree: { slot: "accessory", overflow: "truncate", priority: 30, min: 64 },
  pullRequest: { slot: "accessory", overflow: "hide", priority: 40 },
  // The Needs You count widens the inbox button: it gives way last, and hidden the button keeps a dot
  // (needsYou.css). The inbox button itself is trailing.
  needsYouCount: { slot: "accessory", overflow: "hide", priority: 70, within: ".acpmux-needs-you-button" },
  // trailing: fixed; only the quick actions fold, into "...".
  panel: { slot: "trailing", overflow: "hide" },
  quickActions: { slot: "trailing", overflow: "collapse" },
  menu: { slot: "trailing", overflow: "hide" },
} as const satisfies Record<string, HeaderItemSpec>;

export type HeaderItemId = keyof typeof HEADER_ITEMS;

/// Space between the last tab and the tools, in the width the page reports for the pane's tab row: the tools' own
/// pitch, not a gutter (header/tabRow.ts re-exports it).
export const TAB_ROW_GAP = 4;

export const HEADER_ITEM = "data-header-item";
export const HEADER_SLOT = "data-header-slot";
/// An accessory the room had none for (header.css: display none).
export const HEADER_ITEM_HIDDEN = "data-header-hidden";
/// What a ``HeaderItemSpec.within`` item adds to its control, as last measured (useHeaderSlots).
const HEADER_ITEM_ADDS = "data-header-adds";
export const ACCESSORY_SELECTOR = `[${HEADER_SLOT}="accessory"]`;

/// The room the title keeps beside the tools in a header of its own, so a narrow pane still shows it
/// (headerOverflow.ts folds the quick actions for it too).
export const HEADER_LEADING_RESERVE = 120;

/// The attributes that register `id`'s element in its slot.
export function headerItemProps(id: HeaderItemId): Record<string, string> {
  const spec: HeaderItemSpec = HEADER_ITEMS[id];
  return { [HEADER_ITEM]: id, [HEADER_SLOT]: spec.slot, "data-header-overflow": spec.overflow };
}

/// The width the accessories inside `container` take now, each with the gap after it in its row; hidden ones none.
export function accessoryWidth(container: Element): number {
  let total = 0;
  for (const item of container.querySelectorAll<HTMLElement>(ACCESSORY_SELECTOR)) {
    const width = item.getBoundingClientRect().width;
    if (width <= 0 || item.hasAttribute(HEADER_ITEM_HIDDEN)) continue;
    const adds = item.getAttribute(HEADER_ITEM_ADDS);
    total += adds !== null ? Number(adds) || 0 : width + gapOf(item.parentElement);
  }
  return total;
}

/// What a ``HeaderItemSpec.within`` item adds to its control: the control's width with it, less without it.
function addedWidth(item: HTMLElement, within: string): number {
  const control = item.closest(within);
  if (!control) return 0;
  const shown = control.getBoundingClientRect().width;
  item.setAttribute(HEADER_ITEM_HIDDEN, "");
  const plain = control.getBoundingClientRect().width;
  item.removeAttribute(HEADER_ITEM_HIDDEN);
  return Math.max(0, shown - plain);
}

const px = (value: string | undefined) => Number.parseFloat(value ?? "") || 0;
const gapOf = (element: Element | null) =>
  element ? px(element.ownerDocument.defaultView?.getComputedStyle(element).columnGap) : 0;

export interface AccessoryMeasure {
  readonly id: HeaderItemId;
  /// Its own width, unconstrained (``HeaderItemSpec.width`` when it has one); 0 when it draws nothing.
  readonly natural: number;
  /// The gap after it in its row.
  readonly gap: number;
}

const priorityOf = (id: HeaderItemId) => (HEADER_ITEMS[id] as HeaderItemSpec).priority ?? 0;

/// What each accessory gets of `room`: its natural width (`undefined`), a narrower one, or 0 (hidden). The lowest
/// `priority` gives way first: a `truncate` item narrows to its `min`, then hides; a `hide` or `collapse` item hides.
export function fitAccessories(
  room: number,
  items: readonly AccessoryMeasure[],
): Map<HeaderItemId, number | undefined> {
  const out = new Map<HeaderItemId, number | undefined>();
  const width = new Map<HeaderItemId, number>();
  let used = 0;
  for (const item of items) {
    out.set(item.id, item.natural > 0 ? undefined : 0);
    if (item.natural > 0) {
      width.set(item.id, item.natural);
      used += item.natural + item.gap;
    }
  }
  const order = [...items].filter((item) => item.natural > 0).sort((a, b) => priorityOf(a.id) - priorityOf(b.id));
  for (const item of order) {
    const over = used - Math.max(0, room);
    if (over <= 0) break;
    const spec: HeaderItemSpec = HEADER_ITEMS[item.id];
    const now = width.get(item.id)!;
    const min = spec.min ?? 0;
    if (spec.overflow === "truncate" && now - over >= min && now - over > 0) {
      out.set(item.id, Math.floor(now - over));
      used -= now - Math.floor(now - over);
      continue;
    }
    out.set(item.id, 0);
    used -= now + item.gap;
  }
  return out;
}

/// The room the accessories of a header have: in the pane's tab row, the half of the row the tabs give up less the
/// trailing slot's need; in a header of its own, the header less the trailing slot and the title's reserve.
export function accessoryRoom(mode: "own-row" | "tab-row", rowWidth: number, trailing: number, gap: number): number {
  if (mode === "tab-row") return Math.max(0, Math.floor(rowWidth / 2 - (trailing > 0 ? trailing + TAB_ROW_GAP : 0)));
  return Math.max(0, Math.floor(rowWidth - gap - HEADER_LEADING_RESERVE - trailing));
}

/// Lays out the accessories of `header` (the chat header, `.acpmux-header`): each layout of the header or change in
/// its tools measures every accessory unconstrained, then gives each its share of ``accessoryRoom`` by
/// ``fitAccessories``. All in one task before the frame paints, so nothing draws at a width it then leaves.
export function useHeaderSlots(header: RefObject<HTMLElement | null>, tools: RefObject<HTMLElement | null>): void {
  useLayoutEffect(() => {
    const element = header.current;
    const group = tools.current;
    if (!element || !group || typeof ResizeObserver === "undefined") return;
    const view = element.ownerDocument.defaultView;
    const fit = () => {
      const items = [...group.querySelectorAll<HTMLElement>(`${ACCESSORY_SELECTOR}[${HEADER_ITEM}]`)];
      for (const item of items) {
        item.removeAttribute(HEADER_ITEM_HIDDEN);
        item.removeAttribute(HEADER_ITEM_ADDS);
        item.style.removeProperty("width");
        item.style.removeProperty("max-width");
      }
      const measures: AccessoryMeasure[] = [];
      let accessories = 0;
      for (const item of items) {
        const id = item.getAttribute(HEADER_ITEM) as HeaderItemId;
        const spec: HeaderItemSpec | undefined = HEADER_ITEMS[id];
        if (!spec) continue;
        const drawn = item.getBoundingClientRect().width;
        const own = spec.within && drawn > 0 ? addedWidth(item, spec.within) : drawn;
        const gap = spec.within ? 0 : gapOf(item.parentElement);
        if (spec.within && drawn > 0) item.setAttribute(HEADER_ITEM_ADDS, String(own));
        if (own > 0) accessories += own + gap;
        measures.push({ id, natural: own > 0 ? (spec.width ?? own) : 0, gap });
      }
      const trailing = Math.max(0, Math.round(group.getBoundingClientRect().width - accessories));
      const style = view?.getComputedStyle(element);
      const rowWidth = element.clientWidth - px(style?.paddingLeft) - px(style?.paddingRight);
      const room = accessoryRoom(
        element.hasAttribute("data-tab-row") ? "tab-row" : "own-row",
        rowWidth,
        trailing,
        px(style?.columnGap),
      );
      const given = fitAccessories(room, measures);
      for (const item of items) {
        const id = item.getAttribute(HEADER_ITEM) as HeaderItemId;
        const spec: HeaderItemSpec | undefined = HEADER_ITEMS[id];
        if (!spec || !given.has(id)) continue;
        const width = given.get(id);
        if (width === 0) item.setAttribute(HEADER_ITEM_HIDDEN, "");
        else if (spec.width !== undefined) item.style.width = `${width ?? spec.width}px`;
        else if (width !== undefined) item.style.maxWidth = `${width}px`;
      }
    };
    const resize = new ResizeObserver(fit);
    resize.observe(element);
    resize.observe(group);
    // An accessory that comes, goes or changes its text (a new summary, a pull request found) lays the row out again.
    const mutation = new MutationObserver(fit);
    mutation.observe(group, { childList: true, subtree: true, characterData: true });
    fit();
    return () => {
      resize.disconnect();
      mutation.disconnect();
    };
  }, [header, tools]);
}

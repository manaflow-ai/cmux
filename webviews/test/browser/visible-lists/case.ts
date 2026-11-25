// The contract a visible-only list case keeps (test/browser/visible-lists.harness.tsx).

export interface VisibleListControls {
  /** Matches each mounted row of the list (a listbox's options, say). */
  rowSelector: string;
  /** The components whose renders count as row renders (named functions: the build keeps names). */
  rowComponents: readonly string[];
  /** The element whose scrollTop a scroll step moves. */
  scroller(): HTMLElement;
  /** The list's root: its descendant count is the DOM node count. */
  list(): HTMLElement;
  /** The field a typing step types into, when the list has one. */
  filter?(): HTMLElement;
  /** Change one item's data (a label), as a live update would. */
  changeOne?(): void;
  /** The element whose width a resize step changes (default: the harness root). */
  resizeTarget?(): HTMLElement;
}

export interface VisibleListCase {
  mount(root: HTMLElement, n: number): VisibleListControls | Promise<VisibleListControls>;
}

/** `n` items with stable ids and labels that a filter can narrow ("item 0042 alpha"). */
export function caseItems(n: number): { id: string; label: string }[] {
  const words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"];
  return Array.from({ length: n }, (_, index) => ({
    id: `id-${index}`,
    label: `item ${String(index).padStart(5, "0")} ${words[index % words.length]}`,
  }));
}

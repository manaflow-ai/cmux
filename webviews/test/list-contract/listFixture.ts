// What a list registers to join the list contract (test/list-contract.browser.test.ts, the rules in
// test/support/listContract.ts): a file `test/list-contract/<name>.fixture.tsx` whose default export
// is `listFixture({...})`. The harness page (test/browser/list-contract.harness.tsx) owns the data:
// it builds `items(n)`, keeps them with the clock and the selection in React state, and renders
// `render(...)` in a 420 x 600 px box. Every event the contract measures is one of these:
//   change  items[index] = change(items[index]), a new array, every other item the same object;
//           `index` is the middle row in view, counted among the mounted rows, so a list must
//           start at its first item (one that opens at its end scrolls to its top on mount)
//   scroll  the scroller moves one row
//   hover   the pointer moves onto a row
//   select  `selected` moves to another row (render passes it to the list)
//   tick    `now` moves a minute (a list without a clock still sees its parent render again)
//   width   the box narrows by 20 px
// An event the list does not have is named in `skip` with the reason, which the report prints.
// `render` is a component (it may use hooks), compiled by the React Compiler as the app's are.
import type { ReactNode } from "react";

export type ListEvent = "change" | "scroll" | "hover" | "select" | "tick" | "width";

export type ListFixtureProps<Item> = {
  items: readonly Item[];
  /// The page clock (ms), moved one minute by `tick`.
  now: number;
  /// The selected item's index, moved by `select`.
  selected: number | undefined;
  onSelect(index: number): void;
};

export type ListFixture<Item = unknown> = {
  /// The component under test, `path#Export` from webviews/src, for the report.
  source: string;
  /// One row: what the contract counts as mounted, and what a render is charged to.
  rows: string;
  /// The element that scrolls the rows; "viewport" is its visible box.
  scroller: string;
  /// Rows drawn past each edge of the viewport: viewports (default 1), or a row count. More than
  /// two viewports needs `reason`.
  overscan?: { viewports?: number; rows?: number; reason?: string };
  /// Rows always mounted beside the window (the active row, a sticky header): default 2.
  keep?: number;
  /// Item `index` of the n items the list is mounted with; the harness calls it once per index.
  item(index: number, n: number): Item;
  /// One item's update (its text, its count): a new object.
  change?(item: Item): Item;
  render(props: ListFixtureProps<Item>): ReactNode;
  /// Events the list does not have, each with why.
  skip?: Partial<Record<ListEvent, string>>;
};

export function listFixture<Item>(fixture: ListFixture<Item>): ListFixture<Item> {
  return fixture;
}

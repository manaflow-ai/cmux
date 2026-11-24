import type { ReactElement } from "react";
import type { AcpmuxRow } from "../model";

/// What one mounted row's frame element is drawn from, besides its rows (`RowFrameCache.take`): its
/// place, focus and entrance flags and its repository scope. Each is compared by `Object.is`.
export type RowFrameInputs = {
  index: number;
  top: number;
  gapBelow: number;
  setSize: number;
  expanded: boolean;
  active: boolean;
  selected: boolean;
  tabStop: boolean;
  finalFooter: boolean;
  sendThinking: boolean;
  enter: boolean;
  loadFade: boolean;
  older: unknown;
  repository: string | undefined;
  scope: unknown;
};

const INPUT_KEYS = [
  "index",
  "top",
  "gapBelow",
  "setSize",
  "expanded",
  "active",
  "selected",
  "tabStop",
  "finalFooter",
  "sendThinking",
  "enter",
  "loadFade",
  "older",
  "repository",
  "scope",
] as const satisfies readonly (keyof RowFrameInputs)[];

type Entry = {
  inputs: RowFrameInputs;
  /// The row window's first index and its rows (`rowPropsWindow`), compared by identity.
  first: number;
  window: readonly (AcpmuxRow | undefined)[];
  element: ReactElement;
};

const sameList = (a: readonly unknown[], b: readonly unknown[]) =>
  a.length === b.length && a.every((value, index) => Object.is(value, b[index]));

/// Each mounted row's `RowFrame` element, kept across transcript renders while what it is drawn from
/// stays the same: its rows (the row and the drawn neighbours its joins, edges and reply room read),
/// its `RowFrameInputs`, and what every row shares (callbacks, width, session). A streamed token
/// changes the live row alone, so only that row's props are worked out again and only its element is
/// new; React skips every other frame at once, without comparing its props. Before, each update
/// rebuilt every mounted frame's props and children and compared them: work that grew with the rows
/// in view (a god chat's short turns mount about 60 rows, a long-turn chat about 30).
///
/// A render calls `begin`, then `take` for each mounted row (and `put` when `take` misses), then
/// `end`. It holds only the rows mounted in the last render. `take` allocates nothing.
export class RowFrameCache {
  private entries = new Map<string, Entry>();
  private kept = new Map<string, Entry>();
  private shared: readonly unknown[] = [];
  /// Rows whose props were worked out again (`put`): read by tests and the bench probe.
  derived = 0;
  /// The scratch inputs a render fills for each row before `take`.
  readonly scratch: RowFrameInputs = {
    index: 0,
    top: 0,
    gapBelow: 0,
    setSize: 0,
    expanded: false,
    active: false,
    selected: false,
    tabStop: false,
    finalFooter: false,
    sendThinking: false,
    enter: false,
    loadFade: false,
    older: undefined,
    repository: undefined,
    scope: undefined,
  };

  /// Starts a render. `shared`: what every row's element is drawn from; any change draws them all anew.
  begin(shared: readonly unknown[]): void {
    if (!sameList(shared, this.shared)) this.entries.clear();
    this.shared = shared;
    this.kept = new Map();
  }

  /// The element kept for `key` when `rows` and `scratch` are what it was drawn from, else undefined.
  take(key: string, rows: readonly AcpmuxRow[]): ReactElement | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    const inputs = this.scratch;
    for (const name of INPUT_KEYS) if (!Object.is(entry.inputs[name], inputs[name])) return undefined;
    const { first, window } = entry;
    for (let at = 0; at < window.length; at += 1) if (rows[first + at] !== window[at]) return undefined;
    this.kept.set(key, entry);
    return entry.element;
  }

  /// Keeps `element`, drawn from `scratch` and `rows[first..last]`, for `key`.
  put(key: string, rows: readonly AcpmuxRow[], first: number, last: number, element: ReactElement): ReactElement {
    this.derived += 1;
    const window: (AcpmuxRow | undefined)[] = [];
    for (let at = first; at <= last; at += 1) window.push(rows[at]);
    this.kept.set(key, { inputs: { ...this.scratch }, first, window, element });
    return element;
  }

  /// Ends a render: rows not mounted in it are let go.
  end(): void {
    this.entries = this.kept;
  }
}

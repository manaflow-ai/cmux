// A memoized part of the pane keeps what its parent hands it while that is the same. The pane
// (App.tsx AcpmuxPane) renders on every snapshot it draws (a running command's output alone goes to
// liveToolOutput.ts instead) and builds most of what it hands its header and Session Info inline: new
// callbacks, new option objects, new elements and new lists of the same things. Each made the part
// render again with nothing in it changed (bench/delta-renders.bench.ts: the header and Session Info
// rendered once per output update before liveToolOutput.ts, and still on every other pane render). stableHandlers.ts does this for the composer's `on*` props; this goes through
// every prop, into plain objects, arrays and elements:
//   - a function anywhere in the props is one function per place that calls the latest one there
//     (its presence still counts: a function that comes or goes is a change). An array row's place
//     names its `key` (or `id`), so a row kept from before (an open menu's) runs its own action, not
//     the one that took its index; and `owner` (the chat) changing starts over, so a function kept
//     from one chat never runs another chat's;
//   - a plain object, an array or an element whose parts are all the same as last time is the
//     value given last time, and one with no function in it is itself (data keeps its identity);
//   - anything else (a class instance, a Set, a ref object) compares by identity.
// The functions are for what runs after a render (events, effects, a menu opening): a function the
// part calls while it renders reads what its parent had then, so the part must not take one whose
// result can change without the rest of its props changing (`eager` below).
import { createElement, isValidElement, useRef, type ReactElement } from "react";

type Fn = (...args: unknown[]) => unknown;
type Path = readonly (string | number)[];

/// How deep into plain objects, arrays and elements a prop is compared; deeper, by identity.
const MAX_DEPTH = 10;

const isPlainObject = (value: unknown): value is Record<string, unknown> => {
  if (!value || typeof value !== "object") return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
};

/// The value at `path` in `root`, stepping into an element's props.
function valueAt(root: unknown, path: Path): unknown {
  let at = root;
  for (const key of path) {
    if (at === null || at === undefined) return undefined;
    if (isValidElement(at)) at = (at.props as Record<string, unknown>)[key as string];
    else at = (at as Record<string | number, unknown>)[key];
  }
  return at;
}

export class Stabilizer {
  latest: unknown;
  /// One caller per function's place.
  private calls = new Map<string, { fn: Fn; call: Fn }>();
  /// What each place was handed last time, and what it gave for it. A place is a prop's path; the
  /// places are as many as the largest props seen.
  private raw = new Map<string, unknown>();
  private held = new Map<string, unknown>();
  /// The places each place held inside it last time it was read through, so a place that goes (a
  /// keyed row that left its list, a field no longer handed) takes what it and everything inside it
  /// held with it (review of #37907: 1,000 completed asks stayed held after the list emptied).
  private children = new Map<string, Set<string>>();

  /// How many places hold something (tests).
  get size(): number {
    return new Set([...this.raw.keys(), ...this.held.keys(), ...this.calls.keys(), ...this.children.keys()]).size;
  }

  run(root: Record<string, unknown>): Record<string, unknown> {
    this.latest = root;
    return this.value(root, [], 0) as Record<string, unknown>;
  }

  /// `next` as the place at `path` gives it (`value`), read outside `run`.
  stabilize(next: unknown, path: Path): unknown {
    return this.value(next, path, path.length);
  }

  /// The caller for the function `fn` at `path`: it runs `fn`, and the newest function handed for
  /// the same place after it. A place names its array rows by their `key` (or `id`) too, so a row
  /// kept from an earlier render (an open menu's) runs its own row's action, never the one that took
  /// its spot; and a caller is never handed to another stabilizer (another chat, `useStableProps`).
  private caller(key: string, fn: Fn): Fn {
    let entry = this.calls.get(key);
    if (!entry) {
      const made: { fn: Fn; call: Fn } = { fn, call: (...args: unknown[]) => made.fn(...args) };
      entry = made;
      this.calls.set(key, entry);
    }
    entry.fn = fn;
    return entry.call;
  }

  /// `seen`: the places of the parent's read, which this place joins.
  private value(next: unknown, path: Path, depth: number, seen?: Set<string>): unknown {
    const key = JSON.stringify(path);
    seen?.add(key);
    if (typeof next === "function") return this.caller(key, next as Fn);
    if (depth >= MAX_DEPTH) return next;
    const element = isValidElement(next);
    if (!element && !Array.isArray(next) && !isPlainObject(next)) return next;
    // The same object as last time holds the same parts: what it gave then stands.
    if (this.raw.get(key) === next && this.held.has(key)) return this.held.get(key);
    const before = this.held.get(key);
    const inside = new Set<string>();
    let made: unknown;
    if (element) {
      const el = next as ReactElement<Record<string, unknown>>;
      const props = this.fields(el.props, path, depth, inside);
      const prior = isValidElement(before) ? (before as ReactElement<Record<string, unknown>>) : undefined;
      made =
        prior && prior.type === el.type && prior.key === el.key && sameFields(prior.props, props)
          ? prior
          : sameFields(el.props, props)
            ? el
            : createElement(el.type, el.key === null ? props : { ...props, key: el.key });
    } else if (Array.isArray(next)) {
      const items = next.map((item, index) => this.value(item, [...path, rowPlace(item, index)], depth + 1, inside));
      const sameAs = (list: readonly unknown[]) =>
        list.length === items.length && items.every((item, index) => Object.is(item, list[index]));
      made = Array.isArray(before) && sameAs(before) ? before : sameAs(next) ? next : items;
    } else {
      const source = next as Record<string, unknown>;
      const fields = this.fields(source, path, depth, inside);
      made = isPlainObject(before) && sameFields(before, fields) ? before : sameFields(source, fields) ? next : fields;
    }
    // What was inside this place before and is not now goes: O(its parts), as reading them was.
    const was = this.children.get(key);
    if (was) for (const child of was) if (!inside.has(child)) this.drop(child);
    if (inside.size) this.children.set(key, inside);
    else this.children.delete(key);
    this.raw.set(key, next);
    this.held.set(key, made);
    return made;
  }

  private fields(
    source: Record<string, unknown>,
    path: Path,
    depth: number,
    inside: Set<string>,
  ): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const [field, value] of Object.entries(source))
      out[field] = this.value(value, [...path, field], depth + 1, inside);
    return out;
  }

  /// Place `key` is gone: what it and the places inside it held goes with it.
  private drop(key: string): void {
    this.raw.delete(key);
    this.held.delete(key);
    this.calls.delete(key);
    const inside = this.children.get(key);
    this.children.delete(key);
    if (inside) for (const child of inside) this.drop(child);
  }
}

/// An array row's place: its index, and its `key` (or `id`) when it has one, so a row's functions
/// stay its own when rows are added, removed or reordered.
function rowPlace(item: unknown, index: number): string | number {
  const named = isPlainObject(item) ? (item.key ?? item.id) : isValidElement(item) ? item.key : undefined;
  return typeof named === "string" || typeof named === "number" ? `${index}:${named}` : index;
}

function sameFields(a: Record<string, unknown>, b: Record<string, unknown>): boolean {
  const keys = Object.keys(b);
  return keys.length === Object.keys(a).length && keys.every((key) => key in a && Object.is(a[key], b[key]));
}

/// `props` as a memoized component should get them: the same values while they are the same (see
/// the top of this file). `eager` names function props the component calls while it renders, with
/// the arguments it calls them with: each is called here, on every parent render, and its result is
/// handed over the same way, so the component renders again when that result changes. `owner` is
/// whose props these are (the chat): when it changes every value is new, and the functions handed
/// out before keep calling the old owner's.
export function useStableProps<P extends object>(
  props: P,
  eager?: { [K in keyof P]?: readonly unknown[][] },
  owner?: unknown,
): P {
  const held = useRef<{ owner: unknown; stabilizer: Stabilizer } | undefined>(undefined);
  if (!held.current || !Object.is(held.current.owner, owner)) held.current = { owner, stabilizer: new Stabilizer() };
  const stabilizer = held.current.stabilizer;
  const root: Record<string, unknown> = { ...(props as Record<string, unknown>) };
  const results: Record<string, unknown[]> = {};
  for (const [name, calls] of Object.entries(eager ?? {}) as [string, unknown[][] | undefined][]) {
    const fn = root[name];
    if (typeof fn !== "function" || !calls) continue;
    results[name] = calls.map((args) => (fn as Fn)(...args));
  }
  const stable = stabilizer.run({ props: root, results });
  const out = { ...(stable.props as Record<string, unknown>) };
  const kept = stable.results as Record<string, unknown[]>;
  for (const [name, calls] of Object.entries(eager ?? {}) as [string, unknown[][] | undefined][]) {
    if (!(name in kept) || !calls) continue;
    out[name] = eagerCall(stabilizer, name, calls, kept[name]!);
  }
  return out as P;
}

/// One function per (eager prop, what it gave): a new one when what it gives changed, so the
/// component renders again. Each call reads the latest function again (the component may render for
/// its own state too, and then shows what it gives now), handed over as the parent's render's was:
/// its functions call the latest ones in the parent's reading.
const eagerCalls = new WeakMap<object, Fn>();
function eagerCall(stabilizer: Stabilizer, name: string, calls: unknown[][], results: unknown[]): Fn {
  let call = eagerCalls.get(results);
  if (!call) {
    call = (...args: unknown[]) => {
      const value = (valueAt(stabilizer.latest, ["props", name]) as Fn | undefined)?.(...args);
      const at = calls.findIndex(
        (known) => known.length === args.length && known.every((arg, index) => Object.is(arg, args[index])),
      );
      return at >= 0 ? stabilizer.stabilize(value, ["results", name, at]) : value;
    };
    eagerCalls.set(results, call);
  }
  return call;
}

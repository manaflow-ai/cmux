import { useInsertionEffect, useState } from "react";

// VirtualTranscript's stable callbacks and kept lists, held out of its render: the React Compiler
// does not compile a component that reads or writes a ref while it renders, and left the transcript's
// wrapper uncompiled.

/// The newest props, a stable function per callback prop that calls the newest one, and the list
/// last handed on per list prop.
export class HeldProps {
  private latest: Record<string, unknown>;
  private readonly calls = new Map<string, (...args: unknown[]) => unknown>();
  private readonly lists = new Map<string, readonly unknown[]>();

  constructor(props: object) {
    this.latest = props as Record<string, unknown>;
  }

  /// Points every stable callback at `props`' functions.
  point(props: object): void {
    this.latest = props as Record<string, unknown>;
  }

  /// The stable function for callback prop `key`: it calls the newest props' `key`, if any.
  call(key: string): (...args: unknown[]) => unknown {
    let call = this.calls.get(key);
    if (!call) {
      call = (...args: unknown[]) => (this.latest[key] as ((...args: unknown[]) => unknown) | undefined)?.(...args);
      this.calls.set(key, call);
    }
    return call;
  }

  /// The list last handed on for `key` while `same` finds it the same as `value`, else `value`.
  list(key: string, value: readonly unknown[], same: (a: readonly unknown[], b: readonly unknown[]) => boolean) {
    const before = this.lists.get(key);
    const kept = before && same(before, value) ? before : value;
    this.lists.set(key, kept);
    return kept;
  }
}

/// `props` held for stable callbacks: the newest is written as the render commits, before any layout
/// effect of that commit, so a callback run from one already calls this render's function.
export function useHeldProps(props: object): HeldProps {
  const [held] = useState(() => new HeldProps(props));
  useInsertionEffect(() => held.point(props));
  return held;
}

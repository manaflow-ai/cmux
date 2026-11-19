/**
 * Row patches (acpmux server/row_patch.rs): a watch that asks `rowPatch: true` hears a changed row
 * as only its changed fields, `_acpmux/session_patch {sessionId, peer?, patch, unset?}`, against
 * the last row this connection received of the same chat. A row goes whole
 * (`_acpmux/session_changed`) on its first sight, after a lag, and after every `_acpmux/watch`.
 *
 * An idle desktop on 2026-11-19 moved about 3.5 MB/s from acpmux to the app: every chat pane's
 * watch got each row change as the whole ~4 KB row, where a background command's update changed
 * four counters of it.
 *
 * The book holds, per connection, the last row of each chat this connection received; it starts
 * empty on each new socket, as acpmux's does. A patch with no row held means the two disagree
 * (never expected): it is dropped and the caller reads the list again, which asks acpmux for
 * whole rows.
 */

/** The params of `_acpmux/session_changed` this builds, loosely typed: only the keys it reads. */
type Params = { sessionId?: unknown; peer?: unknown; kind?: unknown; session?: unknown; [key: string]: unknown };

/** What `take` gives back: the `_acpmux/session_changed` params the notice means, or `missing`. */
export type RowNotice = { params: Params } | { missing: true };

/** The key a row is held by: its peer's name (none for this daemon's) and its id. */
function keyOf(params: Params): string | undefined {
  if (typeof params.sessionId !== "string") return undefined;
  const peer = typeof params.peer === "string" ? params.peer : "";
  return `${peer}\u0001${params.sessionId}`;
}

export class RowPatchBook {
  private held = new Map<string, Record<string, unknown>>();

  /** A new connection: acpmux's book for it is empty too. */
  reset(): void {
    this.held.clear();
  }

  /** How many rows it holds. */
  get size(): number {
    return this.held.size;
  }

  /** A whole row (`_acpmux/session_changed`): held as the base of the next patch of its chat. */
  whole(params: Params): void {
    const key = keyOf(params);
    if (key === undefined) return;
    const row = params.session;
    if (params.kind === "purged" || typeof row !== "object" || row === null || Array.isArray(row)) {
      this.held.delete(key);
      return;
    }
    this.held.set(key, row as Record<string, unknown>);
  }

  /** A patch (`_acpmux/session_patch`): the `session_changed` params it means, the row built as
   *  the held row with the patch's fields laid over it and `unset`'s removed. A new object, so a
   *  list keyed on row identity sees the change. */
  patch(params: Params): RowNotice {
    const key = keyOf(params);
    const base = key === undefined ? undefined : this.held.get(key);
    const patch = params.patch;
    if (key === undefined || base === undefined || typeof patch !== "object" || patch === null) {
      if (key !== undefined) this.held.delete(key);
      return { missing: true };
    }
    const row: Record<string, unknown> = { ...base, ...(patch as Record<string, unknown>) };
    if (Array.isArray(params.unset)) for (const field of params.unset) if (typeof field === "string") delete row[field];
    this.held.set(key, row);
    const { patch: _patch, unset: _unset, ...rest } = params;
    return { params: { ...rest, session: row } };
  }
}

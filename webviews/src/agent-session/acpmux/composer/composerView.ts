// The snapshot the composer draws from keeps its identity while nothing the composer shows changed
// (coordinator brief after Leo, 2026-11-07: "the composer and the session info thing ... doing these
// kind of flicker re-renders when you are streaming in text"). Every snapshot acpmux sends is a new
// object with a new `rows` array, and a tool call is one: the pane drew the composer again for each,
// though it shows no tool call. The composer reads its rows only for the person's own prompts (the
// arrow keys' history), a held prompt waiting for its chat, whether the chat has any rows or any past
// its start, and why a failed turn paused the queue; `composerRows` keeps exactly those rows, and
// `useComposerView` hands back the last view while it holds the same values.
import { useRef } from "react";
import { linkUp, type AcpmuxRow, type AcpmuxSnapshot } from "../model";

/// The rows the composer reads (Composer.tsx, ComposerPickers.tsx): the first row and the first past the
/// chat's start (so "no rows" and "started" read the same), every prompt the person sent, every queued
/// row, and every failed turn's summary (queuePause.ts). In order, as `rows` has them.
export function composerRows(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const kept: AcpmuxRow[] = [];
  let started = false;
  for (let index = 0; index < rows.length; index++) {
    const row = rows[index]!;
    const firstStarted = !started && row.kind !== "sessionStart";
    if (row.kind !== "sessionStart") started = true;
    if (
      index === 0 ||
      firstStarted ||
      row.kind === "user" ||
      row.queued !== undefined ||
      (row.kind === "turnSummary" && row.status === "failed")
    )
      kept.push(row);
  }
  return kept;
}

/// The same members by identity, one level down: arrays element by element, anything else by `Object.is`.
function sameMember(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
  for (let index = 0; index < a.length; index++) if (!Object.is(a[index], b[index])) return false;
  return true;
}

/// Whether two views hold the same members (sameMember), key by key.
export function sameComposerView(a: AcpmuxSnapshot, b: AcpmuxSnapshot): boolean {
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  for (const key of keys) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (!sameMember(a[key as keyof AcpmuxSnapshot], b[key as keyof AcpmuxSnapshot])) return false;
  }
  return true;
}

/// The composer's view of `snapshot`: its rows cut to `composerRows`, and its `connection` (which
/// names why the client emitted, a streamed event's kind among them; model.ts `linkUp`) to whether the
/// link is up, which is all the composer could read of it. The last view while it holds the same
/// members (sameComposerView), so a snapshot that changed only what the composer does not show leaves
/// it be.
export function composerView(snapshot: AcpmuxSnapshot): AcpmuxSnapshot {
  return {
    ...snapshot,
    rows: composerRows(snapshot.rows),
    connection: linkUp(snapshot.connection) ? "connected" : snapshot.connection,
  };
}

/// `composerView(snapshot)`, the last one returned while it holds the same members.
export function useComposerView(snapshot: AcpmuxSnapshot): AcpmuxSnapshot {
  const last = useRef<{ from: AcpmuxSnapshot; view: AcpmuxSnapshot } | undefined>(undefined);
  if (last.current?.from === snapshot) return last.current.view;
  const next = composerView(snapshot);
  const view = last.current && sameComposerView(last.current.view, next) ? last.current.view : next;
  last.current = { from: snapshot, view };
  return view;
}

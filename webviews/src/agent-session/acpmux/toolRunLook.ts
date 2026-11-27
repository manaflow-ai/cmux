import { useSyncExternalStore } from "react";

/// How a collapsed tool run's summary line looks (conversation/ToolRun.tsx). `kind`, the default:
/// the glyph of the run's main kind of work and the settled rows' text colour. The others are
/// gallery versions kept beside it (transcript.gallery.ts "tool-run-*"): `pencil` always draws the
/// pencil, as the Codex app does; `quiet` dims the words to the quiet rows' colour; `quiet-pencil`
/// does both. The native host sends no value, so the default holds there.
export type ToolRunLook = "kind" | "pencil" | "quiet" | "quiet-pencil";

const LOOKS: readonly ToolRunLook[] = ["kind", "pencil", "quiet", "quiet-pencil"];
let current: ToolRunLook = "kind";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureToolRunLook(value: unknown): void {
  const next = LOOKS.find((look) => look === value) ?? "kind";
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// The look now.
export const useToolRunLook = (): ToolRunLook => useSyncExternalStore(subscribe, snapshot, snapshot);

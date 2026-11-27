// Each card's Undo, kept outside the card so a card scrolled out of the virtual transcript and
// back keeps its state. Keyed by the card's row id; a new session clears nothing it does not own.
import { useSyncExternalStore } from "react";
import { postNative } from "../native";
import { readUndoReply, undoFiles, undoSummary, type EditedFile, type UndoStatus } from "./model";

export type UndoState =
  | { phase: "idle" }
  | { phase: "checking" }
  /// The dry run's answer, shown as "Undo 2 files? 1 file changed since this turn…".
  | { phase: "confirm"; dryRun: ReadonlyMap<string, UndoStatus>; summary: ReturnType<typeof undoSummary> }
  | { phase: "undoing" }
  | { phase: "done"; result: ReadonlyMap<string, UndoStatus> }
  | { phase: "failed" };

/// The host call; tests replace it.
export type UndoCall = (files: ReturnType<typeof undoFiles>, apply: boolean) => Promise<unknown>;
let call: UndoCall = (files, apply) => postNative("turn.undo", { files, apply });
export function setUndoCall(next: UndoCall) {
  call = next;
}

const IDLE: UndoState = { phase: "idle" };
const states = new Map<string, UndoState>();
const listeners = new Set<() => void>();
function set(key: string, state: UndoState) {
  states.set(key, state);
  for (const listener of listeners) listener();
}

export function useUndoState(key: string): UndoState {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => states.get(key) ?? IDLE,
  );
}

/// The Undo click: asks the host what it would do (no write), then waits for the confirmation.
export async function checkUndo(key: string, files: readonly EditedFile[]) {
  set(key, { phase: "checking" });
  try {
    const dryRun = readUndoReply(await call(undoFiles(files), false));
    set(key, { phase: "confirm", dryRun, summary: undoSummary(files, dryRun) });
  } catch {
    set(key, { phase: "failed" });
  }
}

/// The confirmation's Undo: only the files the dry run said it would put back.
export async function applyUndo(key: string, files: readonly EditedFile[]) {
  const state = states.get(key);
  if (state?.phase !== "confirm") return;
  const chosen = files.filter((file) => {
    const status = state.dryRun.get(file.path);
    return status === "wouldRevert" || status === "wouldTrash";
  });
  set(key, { phase: "undoing" });
  try {
    const answer = readUndoReply(await call(undoFiles(chosen), true));
    const result = new Map(state.dryRun);
    for (const [path, status] of answer) result.set(path, status);
    set(key, { phase: "done", result });
  } catch {
    set(key, { phase: "failed" });
  }
}

export function cancelUndo(key: string) {
  set(key, IDLE);
}

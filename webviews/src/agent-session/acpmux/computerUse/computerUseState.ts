// Whether Computer Use is set up on this Mac, for the composer's `@computer-use` (toolMentions.ts,
// CMUX-682). The app pushes it to every page at load and on every change of its one Computer Use
// Setup (AgentPaneComputerUseState.swift, `computerUseState` event): `ready` (the helper holds both
// grants), `starting` (no answer yet), `needs_setup` (off, a grant missing, failed) or `disabled` (the
// organization turned it off). The page never asks and never waits: a send reads the state as it is
// now. An app too old to push it leaves it unknown, and nothing is held.
import { useSyncExternalStore } from "react";
import { toolMentionsIn } from "../toolMentions";

export type ComputerUseState = "ready" | "starting" | "needs_setup" | "disabled";

/// The app's answer, or undefined for anything else (an older app, null while unknown).
export function readComputerUseState(value: unknown): ComputerUseState | undefined {
  return value === "ready" || value === "starting" || value === "needs_setup" || value === "disabled"
    ? value
    : undefined;
}

/// Whether a send that names `@computer-use` waits (Lucas 2026-11-21: "do not let the user do
/// @computer-use if it is not working/enabled"): every answer but `ready`. Only an app too old to
/// answer (unknown) sends, since nothing here can tell; the agent's own tool then says what is wrong.
export function holdsForComputerUse(
  state: ComputerUseState | undefined,
): state is "needs_setup" | "disabled" | "starting" {
  return state !== undefined && state !== "ready";
}

/// What a send of `text` does about Computer Use (`state`, the app's latest push): `free` (it names no
/// `@computer-use`, or Computer Use is ready, or an app too old to answer), `setup` (hold it and open
/// the setup page: off, a grant missing, still starting) or `notice` (hold it and say why: turned off
/// by the organization, which no setup can change).
export function computerUseGate(text: string, state: ComputerUseState | undefined): "free" | "setup" | "notice" {
  if (!toolMentionsIn(text).includes("computer-use") || !holdsForComputerUse(state)) return "free";
  return state === "disabled" ? "notice" : "setup";
}

let current: ComputerUseState | undefined;
const listeners = new Set<() => void>();

/// The app's push (pageHost.ts `computerUseState`); anything else reads as unknown.
export function setComputerUseState(value: unknown): void {
  const next = readComputerUseState(value);
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

/// The state now, for a send's handler (read at the moment it decides).
export function computerUseState(): ComputerUseState | undefined {
  return current;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/// The state, for a render (the "not set up" notice clears once it is ready).
export function useComputerUseState(): ComputerUseState | undefined {
  return useSyncExternalStore(subscribe, computerUseState, computerUseState);
}

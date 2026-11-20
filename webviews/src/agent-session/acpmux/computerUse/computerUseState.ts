// Whether Computer Use is set up on this Mac, for the composer's `@computer-use` (toolMentions.ts,
// CMUX-682). The app answers `chat.computerUse.state` from its one Computer Use Setup model
// (AgentPaneComputerUseState.swift): `ready` (the helper holds both grants), `starting` (no answer
// yet), `needs_setup` (off, a grant missing, failed) or `disabled` (the organization turned it off).
// An app too old to answer leaves it unknown, and nothing is held.
//
// The page reads it once when it loads, again on each send it held, and, only after the person
// pressed Set Up Computer Use, once when the page comes back to the front (the setup ran in
// onboarding and System Settings meanwhile), as harness health does after a Log In. Never on a
// timer, and a chat switch with no setup run reads nothing.
import { useCallback, useEffect, useRef, useState } from "react";
import { callNative } from "../callNative";
import { toolMentionsIn } from "../toolMentions";

export type ComputerUseState = "ready" | "starting" | "needs_setup" | "disabled";

/// The app's answer, or undefined for anything else (an older app, a failure).
export function readComputerUseState(value: unknown): ComputerUseState | undefined {
  const state = value && typeof value === "object" ? (value as { state?: unknown }).state : undefined;
  return state === "ready" || state === "starting" || state === "needs_setup" || state === "disabled"
    ? state
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

/// What a send of `text` does about Computer Use, from the last answer (`state`): `free` (it names no
/// `@computer-use`, or Computer Use is ready, or an app too old to answer), `setup` (hold it and open
/// the setup page: off, a grant missing, still starting) or `notice` (hold it and say why: turned off
/// by the organization, which no setup can change).
export function computerUseGate(text: string, state: ComputerUseState | undefined): "free" | "setup" | "notice" {
  if (!toolMentionsIn(text).includes("computer-use") || !holdsForComputerUse(state)) return "free";
  return state === "disabled" ? "notice" : "setup";
}

const askState = () => callNative("chat.computerUse.state");

/// The last answer to `chat.computerUse.state`; only the newest answer lands. `refresh` resolves
/// with a fresh one (a send decides on it, never on `state`). `setupRan` marks the answer stale until
/// the page next comes to the front, which reads it once more.
export function useComputerUseState(): {
  state: ComputerUseState | undefined;
  refresh(): Promise<ComputerUseState | undefined>;
  setupRan(): void;
} {
  const [state, setState] = useState<ComputerUseState | undefined>();
  const [stale, setStale] = useState(false);
  const generation = useRef(0);
  const refresh = useCallback(() => {
    const mine = ++generation.current;
    const land = (next: ComputerUseState | undefined) => {
      // A newer read is on its way: this send still decides on what it read.
      if (mine !== generation.current) return next;
      setState(next);
      return next;
    };
    return askState().then(
      (reply) => land(readComputerUseState(reply)),
      () => land(undefined),
    );
  }, []);
  // mount-read: one main-actor read of the app's Computer Use Setup, no daemon or disk; a send that
  // names @computer-use needs it before the person presses Return.
  useEffect(() => void refresh(), [refresh]);
  useEffect(() => {
    if (!stale) return;
    const back = () => {
      if (document.visibilityState !== "visible") return;
      setStale(false);
      void refresh();
    };
    window.addEventListener("focus", back);
    document.addEventListener("visibilitychange", back);
    return () => {
      window.removeEventListener("focus", back);
      document.removeEventListener("visibilitychange", back);
    };
  }, [stale, refresh]);
  const setupRan = useCallback(() => setStale(true), []);
  return { state, refresh, setupRan };
}

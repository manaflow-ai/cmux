// Whether Computer Use is set up on this Mac, for the composer's `@computer-use` (toolMentions.ts,
// CMUX-682). The app pushes it to every page at load and on every change of its one Computer Use
// Setup (AgentPaneComputerUseState.swift, `computerUseState` event): `ready` (the helper holds both
// grants), `starting` (no answer yet), `needs_setup` (off, a grant missing, failed), `unavailable`
// (this build has no cmux Remote, or one of another version: no setup can fix it) or `disabled` (the
// organization turned it off). The page never asks and never waits: a send reads the state as it is
// now. An app too old to push it leaves it unknown, and nothing is held.
import { useSyncExternalStore } from "react";
import type { StringKey } from "../i18n";
import { toolMentionsIn } from "../toolMentions";
import type { ComposerAttachment } from "../attachments";

export type ComputerUseState = "ready" | "starting" | "needs_setup" | "unavailable" | "disabled";

/// Where the chat a send goes to runs: this Mac, a Cloud machine (a Cloud VM chat, a Sandboxed run)
/// or another machine (a peer, an SSH host). Only a chat on this Mac gets cmux's Computer Use tools:
/// acpmux gives a remote-origin session no cmux tools, and nothing routes a VM back to this Mac (#48541).
export type ComputerUsePlace = "here" | "cloud" | "machine";

/// Why a send that names `@computer-use` is held, and what the notice says: `setup` (off, a grant
/// missing, still starting: the setup page fixes it), `unavailable` (this build cannot run it),
/// `disabled` (the organization turned it off), `cloud` / `machine` (the chat does not run on this Mac).
export type ComputerUseHold = "setup" | "unavailable" | "disabled" | "cloud" | "machine";

/// The app's answer, or undefined for anything else (an older app, null while unknown, a newer
/// app's state this page does not know: those send, as before).
export function readComputerUseState(value: unknown): ComputerUseState | undefined {
  return value === "ready" ||
    value === "starting" ||
    value === "needs_setup" ||
    value === "unavailable" ||
    value === "disabled"
    ? value
    : undefined;
}

/// Whether a send that names `@computer-use` waits (Lucas 2026-11-21: "do not let the user do
/// @computer-use if it is not working/enabled"): every answer but `ready`. Only an app too old to
/// answer (unknown) sends, since nothing here can tell; the agent's own tool then says what is wrong.
export function holdsForComputerUse(state: ComputerUseState | undefined): state is Exclude<ComputerUseState, "ready"> {
  return state !== undefined && state !== "ready";
}

/// Why a send naming `@computer-use` to a chat in `place` waits, with this Mac's `state`; undefined:
/// it goes. A chat off this Mac waits whatever the state, since it has no Computer Use tools at all.
export function computerUseHold(
  state: ComputerUseState | undefined,
  place: ComputerUsePlace = "here",
): ComputerUseHold | undefined {
  if (place !== "here") return place;
  if (!holdsForComputerUse(state)) return undefined;
  return state === "disabled" || state === "unavailable" ? state : "setup";
}

/// What a send of `text` does about Computer Use (`state`, the app's latest push; `place`, where the
/// chat runs): `free` (it names no `@computer-use`, or Computer Use is ready on this Mac, or an app
/// too old to answer), `setup` (hold it and open the setup page) or another hold (hold it and say why:
/// no setup can change it).
export function computerUseGate(
  text: string,
  state: ComputerUseState | undefined,
  place: ComputerUsePlace = "here",
): "free" | ComputerUseHold {
  if (!toolMentionsIn(text).includes("computer-use")) return "free";
  return computerUseHold(state, place) ?? "free";
}

/// Whether a `hold` opens the setup page (Lucas, standup 2026-11-20 and 2026-11-22: "if Computer Use is
/// not set up or not working, the setup page opens"): not set up, and a build that cannot run it, whose
/// setup page says so and how to get a build that can. Turned off by the organization, or a chat off
/// this Mac, only says why: no setup on this Mac changes it.
export function holdOpensSetup(hold: ComputerUseHold): boolean {
  return hold === "setup" || hold === "unavailable";
}

/// What a send's Computer Use check reads: the words and every pasted-text chip, which goes as text the
/// agent (and acpmux's note) reads as the person's too (CMUX-682).
export function sentWords(text: string, attachments: readonly ComposerAttachment[] = []): string {
  const pasted = attachments.flatMap((attachment) =>
    attachment.kind === "pasted" && attachment.text ? [attachment.text] : [],
  );
  return pasted.length ? [text, ...pasted].join("\n\n") : text;
}

/// The notice's words for `hold` (ComputerUseSetupNotice.tsx; New Tab's toast is the title alone).
export function computerUseHoldText(hold: ComputerUseHold): { title: StringKey; detail?: StringKey } {
  switch (hold) {
    case "setup":
      return { title: "computerUseSetup.title", detail: "computerUseSetup.detail" };
    case "disabled":
      return { title: "computerUseSetup.disabledTitle" };
    case "unavailable":
      return { title: "computerUseSetup.unavailableTitle", detail: "computerUseSetup.unavailableDetail" };
    case "cloud":
      return { title: "computerUseSetup.remoteTitle", detail: "computerUseSetup.cloudDetail" };
    case "machine":
      return { title: "computerUseSetup.remoteTitle", detail: "computerUseSetup.machineDetail" };
  }
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

declare global {
  interface Window {
    /// The old host's script for the `computerUseState` event (CmuxNextAgentPane AgentPaneComputerUse):
    /// with `agent.pageHost` off (the default) the state comes this way, not as a page host event.
    cmuxAcpmuxComputerUseState?: (value: unknown) => void;
  }
}
/// Installs the old host's hook on `target` (the page's window).
export function installComputerUseStateHook(target: Pick<Window, "cmuxAcpmuxComputerUseState">) {
  target.cmuxAcpmuxComputerUseState = setComputerUseState;
}
// On the page's window only, as diffColors.ts and the other host hooks: a test with no window gets no
// global it would leave behind for the next test file (test/support/leakDetector.ts).
if (typeof window !== "undefined") installComputerUseStateHook(window);

// The agent chat page's layout-motion audit (layout/motionAudit.ts), in dev builds only: a `cmux-dev` link
// scheme (a tagged dev build, the dev host) or the Vite dev page. Each undeclared move goes to the flicker
// ring (`layout-undeclared`) and the console. Release and NIGHTLY pay nothing for it.
import { useEffect } from "react";
import { declareMove } from "../../layout/motionContract";
import { startMotionAudit, type MotionAudit } from "../../layout/motionAudit";
import { noteUndeclaredMove } from "./flickerLog";

let audit: MotionAudit | undefined;

export const isDevScheme = (scheme: unknown): boolean => typeof scheme === "string" && /^cmux-dev(?:-|$)/.test(scheme);

/** Starts the audit once, when this page is a dev build's; `cmuxMotionAudit.report()` lists what it found. */
export function startDevMotionAudit(scheme: unknown, win: Window = window): void {
  if (audit || !(import.meta.env?.DEV || isDevScheme(scheme))) return;
  try {
    audit = startMotionAudit(win, (move) => {
      const px = Math.max(Math.abs(move.dx), Math.abs(move.dy), Math.abs(move.dw), Math.abs(move.dh));
      noteUndeclaredMove(move.surface, px, move.during.join(",") || "none");
      console.warn(`[layout-motion] undeclared move of ${move.label} (${move.surface})`, move);
    });
    (win as Window & { cmuxMotionAudit?: MotionAudit }).cmuxMotionAudit = audit;
  } catch {
    // The pane matters more than its audit.
  }
}

// The `stream-append` declaration, open only while a reply is growing the transcript's end *and* the
// view follows that end. The contract says so in as many words ("rows above it rise with it only
// while the view follows the end"), and the narrowing is the point: a reader parked up in the
// finished turns sees the growth land below the view, so on screen nothing may move, and a row that
// moves anyway is a shift with nothing to excuse it (Leo, 2026-11-22: "IT FUCKING JUMPS ... AND I
// SHOULDN'T HAVE TO KEEP FUCKING IDENTIFYING THIS SHIT"). Held outside React so a follow change
// opens or closes the declaration without re-rendering the pane.
let streamAppendEnd: (() => void) | undefined;
let appendWorking = false;
let appendFollowing = true;

function syncStreamAppend(): void {
  const want = appendWorking && appendFollowing;
  if (want === (streamAppendEnd !== undefined)) return;
  if (want)
    streamAppendEnd = declareMove({ event: "stream-append", scope: "all", by: "turn working, view at the end" });
  else {
    streamAppendEnd?.();
    streamAppendEnd = undefined;
  }
}

/** While a reply streams and the view follows the end, the transcript grows there: a declared move of
 *  its rows (schemas/layout-motion/contract.json `stream-append`), judged by the layout-motion audit. */
export function useStreamAppendDeclaration(working: boolean): void {
  useEffect(() => {
    appendWorking = working;
    syncStreamAppend();
    return () => {
      appendWorking = false;
      syncStreamAppend();
    };
  }, [working]);
}

/** The transcript's follow state, as the pane learns it (VirtualTranscript `onFollowingChange`).
 *  Away from the end nothing on screen may move, so `stream-append` excuses nothing. */
export function noteTranscriptFollowing(following: boolean): void {
  if (appendFollowing === following) return;
  appendFollowing = following;
  syncStreamAppend();
}

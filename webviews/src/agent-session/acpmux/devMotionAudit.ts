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
  if (audit || !(import.meta.env.DEV || isDevScheme(scheme))) return;
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

/** While a reply streams, the transcript grows at its end: a declared move of its rows
 *  (schemas/layout-motion/contract.json `stream-append`), judged by the layout-motion audit. */
export function useStreamAppendDeclaration(working: boolean): void {
  useEffect(
    () => (working ? declareMove({ event: "stream-append", scope: "all", by: "turn working" }) : undefined),
    [working],
  );
}

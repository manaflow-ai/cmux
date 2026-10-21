// Ctrl-B moves a Claude Code chat's running work to the background, as Ctrl-B does in Claude Code
// itself (Leo 2026-10-20: "where is ctrl/cmd b here?"). acpmux's `_acpmux/process/background`
// sends Claude Code's `background_tasks` control request, and the shells it moved come back as the
// summary card's running Background tasks (docs/background-processes.md). ⌘B stays the left
// sidebar's: the app takes it before the page sees it (cmux-next.json `toggleLeftSidebar`). In the
// composer Ctrl-B is the text system's caret back, so the page takes it only while a call runs in
// the foreground, and a running command's row says so.
import { createContext, useEffect, useRef } from "react";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { continuesTurn } from "../turnStart";

/// Moves the chat's foreground work to the background: only the call `toolCallId` started, or all
/// of it. Absent when the chat cannot (another harness, or no acpmux to ask).
export type RunInBackground = (toolCallId?: string) => void;

export const RunInBackgroundContext = createContext<RunInBackground | undefined>(undefined);

/// Whether acpmux moves this chat's work: its summary says so (`backgroundsWork`, a Claude Code
/// chat whatever its harness is named, the model router's `cmux` too), and the chat is local. acpmux
/// refuses the other harnesses (Codex moves a long command to the background itself), and a peer's
/// or a Cloud chat's processes are not this acpmux's to move. An acpmux that does not say gets none.
export function backgroundsWork(summary: Partial<NonNullable<AcpmuxSnapshot["summary"]>> | undefined): boolean {
  return summary?.backgroundsWork === true && !summary.peer && summary.hostKind !== "cloud";
}

/// The calls of the running turn that hold it up: a running command or subagent (what Claude
/// Code's Ctrl-B moves). A call stays `pending` after its permission prompt is answered, so pending
/// calls count too. Read from the end back to the prompt that opened the turn, past steers and
/// prompts still sending or never sent, as subagents/subagentRows.ts `runningGroups` does.
export function foregroundCalls(rows: readonly AcpmuxRow[]): string[] {
  const calls: string[] = [];
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    if (row.kind === "user" && !row.pending && !row.failed && !continuesTurn(row)) break;
    for (const item of row.items ?? []) {
      const tool = item.tool;
      if (!tool || (tool.status !== "pending" && tool.status !== "in_progress")) continue;
      if (tool.kind === "execute" || tool.kind === "think") calls.push(tool.id);
    }
  }
  return calls;
}

/// Ctrl-B alone, by the character typed (Claude Code reads it the same way).
export function isBackgroundKey(
  event: Pick<KeyboardEvent, "key" | "ctrlKey" | "metaKey" | "altKey" | "shiftKey">,
): boolean {
  return event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "b";
}

/// Takes Ctrl-B on the whole page while `active` (a foreground call or subagent runs), before the composer's
/// caret back. A held key moves the work once.
export function useBackgroundKey(active: boolean, onBackground: () => void): void {
  const latest = useRef(onBackground);
  latest.current = onBackground;
  useEffect(() => {
    if (!active) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || !isBackgroundKey(event)) return;
      event.preventDefault();
      event.stopPropagation();
      if (!event.repeat) latest.current();
    };
    // ui-allow: Ctrl-B moves the running call to the background wherever focus is in the chat, as in Claude Code; no src/ui widget watches the page's keys.
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [active]);
}

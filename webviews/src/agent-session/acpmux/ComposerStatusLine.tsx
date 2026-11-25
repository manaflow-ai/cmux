import React, { useEffect, useState } from "react";

// The person's own status line under the prompt (Settings > Agent Chat > Composer > Status Line
// Command, `agentPane.statusLine.command`), as Claude Code's `statusLine`: acpmux runs the command
// the settings file names with the chat's session JSON on stdin and answers the first line it
// prints (`_acpmux/status_line`, cmux-tui acpmux status_line.rs). The page never sees or sends the
// command. Unset (the default), acpmux answers no line and nothing draws: the composer is as it was.

/// How long the chat's state holds still before the line is asked for: a turn's end changes
/// several fields at once, and they make one ask.
export const STATUS_LINE_SETTLE_MS = 250;

/// Asks acpmux for chat `sessionId`'s line (direct.ts `statusLine`); undefined is no line.
export type AskStatusLine = (sessionId: string) => Promise<string | undefined>;

/// Chat `sessionId`'s status line: asked when the chat opens and again each time `state` changes
/// (its status, turn count, model and mode: a turn ending, a model switch), never on a timer. A
/// switch to another chat drops the old chat's line at once, and an answer for a chat no longer
/// shown is dropped.
export function useComposerStatusLine(
  ask: AskStatusLine | undefined,
  sessionId: string | undefined,
  state: string,
): string | undefined {
  const [shown, setShown] = useState<{ sessionId: string; line: string } | undefined>(undefined);
  useEffect(() => {
    if (!ask || !sessionId) return;
    let live = true;
    const timer = setTimeout(() => {
      ask(sessionId).then(
        (line) => {
          if (!live) return;
          setShown(line ? { sessionId, line } : undefined);
        },
        () => {},
      );
    }, STATUS_LINE_SETTLE_MS);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [ask, sessionId, state]);
  return shown && shown.sessionId === sessionId ? shown.line : undefined;
}

/// The line, one muted row under the composer on the quiet row's column, cut with an ellipsis
/// past the pane's width (its whole text in the tooltip).
export function ComposerStatusLine({ line }: { line: string }) {
  return (
    <div className="acpmux-composer-status-line" title={line} data-composer-status-line="">
      {line}
    </div>
  );
}

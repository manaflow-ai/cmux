// The branch's pull request review threads (cx-ncc.77.2, Codex desktop's inline PR comments): the
// App reads them with the GitHub CLI (`git.pullRequest {action: "threads"}`) and the Branch scope
// shows each under the line it is on, or above the file's diff when that line is gone.
import type { DiffEdit } from "../diff";

export type ReviewComment = { author: string; body: string; url?: string };
export type ReviewThread = {
  path: string;
  /// The line on the head; none for an outdated thread.
  line?: number;
  side: "additions" | "deletions";
  resolved: boolean;
  outdated: boolean;
  /// The file differs here from the pull request's head, so `line` may name another line.
  moved: boolean;
  comments: ReviewComment[];
};

const https = (value: unknown) => (typeof value === "string" && value.startsWith("https://") ? value : undefined);

/// The threads in the App's answer; anything else reads as none.
export function readReviewThreads(value: unknown): ReviewThread[] {
  const threads = (value as { threads?: unknown } | null)?.threads;
  if (!Array.isArray(threads)) return [];
  return threads.flatMap((thread): ReviewThread[] => {
    if (!thread || typeof thread !== "object") return [];
    const { path, line, side, resolved, outdated, moved, comments } = thread as Record<string, unknown>;
    if (typeof path !== "string" || !path) return [];
    return [
      {
        path,
        line: typeof line === "number" && line > 0 ? line : undefined,
        side: side === "deletions" ? "deletions" : "additions",
        resolved: resolved === true,
        outdated: outdated === true,
        moved: moved === true,
        comments: (Array.isArray(comments) ? comments : []).flatMap((comment): ReviewComment[] => {
          const { author, body, url } = (comment ?? {}) as Record<string, unknown>;
          return typeof body === "string"
            ? [{ author: typeof author === "string" ? author : "", body, url: https(url) }]
            : [];
        }),
      },
    ];
  });
}

/// Whether the edit shows the thread's line on its side, so the thread can sit under it (not
/// when the file changed here since the pull request's head: that number may be another line).
export function showsLine(edit: DiffEdit, thread: ReviewThread) {
  if (thread.line === undefined || thread.moved) return false;
  return edit.hunks.some((hunk) =>
    hunk.lines.some((line) =>
      thread.side === "additions"
        ? line.type !== "del" && line.newLine === thread.line
        : line.type !== "add" && line.oldLine === thread.line,
    ),
  );
}

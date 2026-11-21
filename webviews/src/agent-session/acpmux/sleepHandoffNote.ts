// Keep Chats Running When This Mac Sleeps (Settings > Agents): what the chat says about a move
// acpmux made when the Mac went to sleep (cmux-tui acpmux `cli/run/sleep_handoff.rs`). It reads
// only the chat's own summary: `movedTo` (with `why: "sleep"`) on this Mac's copy, the
// `sleepHandoff*` tags on the copy that moved or the chat that stayed.

/** The note a chat shows, or none. */
export type SleepHandoffNote =
  /** This Mac's copy: the chat moved to `machine` when the Mac slept; `routed` opens it there. */
  | { kind: "moved"; machine: string; routed: string | undefined }
  /** The chat that moved, its turn still running on `machine`; `from` is the Mac it left. */
  | { kind: "running"; machine: string | undefined; from: string }
  /** The chat that moved, between turns now. */
  | { kind: "ran"; machine: string | undefined; from: string }
  /** The chat stayed on this Mac when it slept, and why. */
  | { kind: "stayed"; why: string };

type Summary = { movedTo?: unknown; tags?: unknown; peer?: unknown } | undefined;

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined;

/** The note for the chat `summary` (`_acpmux/info`), whose turn runs when `working`. */
export function sleepHandoffNote(summary: Summary, working: boolean): SleepHandoffNote | undefined {
  if (!summary) return undefined;
  const moved = summary.movedTo as { why?: unknown; host?: unknown; sessionId?: unknown } | null | undefined;
  if (moved && typeof moved === "object") {
    const machine = text(moved.host);
    if (moved.why !== "sleep" || !machine) return undefined;
    const id = text(moved.sessionId);
    return { kind: "moved", machine, routed: id && (id.startsWith(`${machine}/`) ? id : `${machine}/${id}`) };
  }
  const tags = summary.tags as Record<string, unknown> | null | undefined;
  if (!tags || typeof tags !== "object") return undefined;
  const mark = tags.sleepHandoff;
  if (mark === "moved") {
    const from = text(tags.sleepHandoffFrom);
    if (!from) return undefined;
    return { kind: working ? "running" : "ran", machine: text(summary.peer), from };
  }
  if (mark === "stayed") {
    const why = text(tags.sleepHandoffWhy);
    return why ? { kind: "stayed", why } : undefined;
  }
  return undefined;
}

/** Whether two notes say the same, so a snapshot that changes nothing keeps the last one. */
export function sameSleepHandoffNote(a: SleepHandoffNote | undefined, b: SleepHandoffNote | undefined): boolean {
  if (a === b) return true;
  if (!a || !b || a.kind !== b.kind) return false;
  return JSON.stringify(a) === JSON.stringify(b);
}

// The Review queue (dealbreakers X7, Leo 2026-11-08): one list of every agent's changes waiting on
// the person, across chats and worktrees, newest needing you first. A row is one folder (a worktree,
// else the chat's folder) with the chat that last worked in it, what its branch changes (`git.diff`,
// no patch) and that chat's last turn. Accept or Request changes tags the chat `review.done` with
// the verdict and the change's signature, so the row leaves the queue on every device until the
// folder's changes differ again.
//
// Interaction cost stays flat as chats grow: the candidates come from the session list alone
// (sorted, nothing read), and a folder's changes are read only for the rows the person can reach
// (`READ_WINDOW` past the last shown row), a few at a time. A row shows only once every row above it
// was read, so rows arrive at the bottom and never push the one under the cursor.
import type { ChangedFile, ChangeSet } from "../changes/model";
import { readChangeSet } from "../changes/model";
import { activityTime, listed, type AcpmuxSessionEntry } from "../sessionList";

/// The tag a verdict leaves on the chat (acpmux `_acpmux/tag`): `accepted:<signature>` or
/// `changes:<signature>`.
export { REVIEW_DONE_TAG as REVIEW_TAG } from "../sessionList";

/// Chats idle longer than this leave the queue: an old worktree is not waiting on anyone.
export const REVIEW_HORIZON_MS = 14 * 24 * 60 * 60 * 1000;

/// How many rows past the cursor are read ahead (and how many candidates past the last reached one
/// a batch may look at), and how many reads run at once.
export const READ_WINDOW = 12;
export const READ_CONCURRENCY = 3;

export type ReviewVerdict = "accepted" | "changes";

/// One folder whose changes may wait on the person.
export type ReviewCandidate = {
  /// The folder: the chat's worktree, else its folder.
  key: string;
  /// The chat that last worked in the folder: it gets the comment, and its turn labels the row.
  owner: AcpmuxSessionEntry;
  /// Other chats in the same folder.
  others: number;
  /// Every `review.done` value the folder's chats carry.
  done: string[];
  /// When the owner last did something (sort key).
  at: number;
  /// The owner's turn is still running: its changes are not final yet, so it sorts after the idle ones.
  working: boolean;
};

/// A folder's changes, as `git.diff` named them.
export type ReviewStat = {
  scope: "branch" | "uncommitted";
  head?: string;
  base?: string;
  files: ChangedFile[];
  additions: number;
  deletions: number;
  totalFiles: number;
  signature: string;
};

export type ReviewRead = { state: "reading" } | { state: "failed" } | { state: "read"; stat?: ReviewStat };

export type ReviewRow = ReviewCandidate & { stat: ReviewStat };

/// The folders worth reading, needing you first: a chat on this Mac with a folder, listed (not
/// archived, not a side chat), active within the horizon, whose pull request (if any) is not merged
/// or closed. Idle owners first, then running ones, each newest first.
export function reviewCandidates(sessions: readonly AcpmuxSessionEntry[], now = Date.now()): ReviewCandidate[] {
  const folders = new Map<string, { owner: AcpmuxSessionEntry; at: number; count: number; done: string[] }>();
  for (const session of sessions) {
    const key = session.worktree ?? session.cwd;
    if (!key || !key.startsWith("/") || !listed(session) || session.unsent) continue;
    // Another machine's folder is read by that machine's session host; this page reads this Mac's.
    if (session.peer || session.hostKind === "cloud") continue;
    const state = session.pullRequest?.state;
    if (state === "merged" || state === "closed") continue;
    const at = activityTime(session) ?? session.updatedAt ?? 0;
    if (now - at > REVIEW_HORIZON_MS) continue;
    const folder = folders.get(key) ?? { owner: session, at, count: 0, done: [] };
    folder.count += 1;
    if (session.reviewDone) folder.done.push(session.reviewDone);
    if (at > folder.at || folder.owner === session) Object.assign(folder, { owner: session, at });
    folders.set(key, folder);
  }
  return [...folders.entries()]
    .map(([key, folder]) => ({
      key,
      owner: folder.owner,
      others: folder.count - 1,
      done: folder.done,
      at: folder.at,
      working: folder.owner.lane === "working" || folder.owner.indicator === "working",
    }))
    .sort((left, right) => Number(left.working) - Number(right.working) || right.at - left.at);
}

/// A `git.diff` reply (no patch) as a review stat, or undefined when it changes nothing.
export function readReviewStat(value: unknown, scope: ReviewStat["scope"]): ReviewStat | undefined {
  const set: ChangeSet | undefined = readChangeSet(value, scope);
  if (!set || set.files.length === 0) return undefined;
  const files = set.files.map(({ path, previousPath, status, additions, deletions, binary }) => ({
    path,
    ...(previousPath ? { previousPath } : {}),
    status,
    additions,
    deletions,
    ...(binary ? { binary } : {}),
  }));
  const additions = set.additions || files.reduce((sum, file) => sum + file.additions, 0);
  const deletions = set.deletions || files.reduce((sum, file) => sum + file.deletions, 0);
  return {
    scope,
    ...(set.head ? { head: set.head } : {}),
    ...(set.base ? { base: set.base } : {}),
    files,
    additions,
    deletions,
    totalFiles: Math.max(set.totalFiles ?? 0, files.length),
    signature: reviewSignature(scope, set.head, files),
  };
}

/// What identifies one state of a folder's changes: its HEAD and every changed file's path, status
/// and counts. A verdict holds while this stays the same; any further edit makes the row come back.
export function reviewSignature(scope: string, head: string | undefined, files: readonly ChangedFile[]): string {
  const lines = files
    .map(
      (file) =>
        `${file.path}\u0000${file.previousPath ?? ""}\u0000${file.status}\u0000${file.additions}\u0000${file.deletions}`,
    )
    .sort();
  return fnv1a([scope, head ?? "", ...lines].join("\n"));
}

function fnv1a(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

/// The tag value a verdict on `stat` leaves.
export const verdictTag = (verdict: ReviewVerdict, stat: ReviewStat) => `${verdict}:${stat.signature}`;

/// Whether a verdict covers the folder's changes as they are now.
export function decided(candidate: ReviewCandidate, stat: ReviewStat, local: ReadonlySet<string> = new Set()): boolean {
  const suffix = `:${stat.signature}`;
  return local.has(`${candidate.key}${suffix}`) || candidate.done.some((value) => value.endsWith(suffix));
}

/// What the page shows: the candidates read so far in order, stopping at the first one still being
/// read or not read yet (rows only ever arrive below), without the clean, failed and decided ones.
/// `pending` is whether a read above the end still runs; `reached` how many candidates are read.
export function reviewRows(
  candidates: readonly ReviewCandidate[],
  reads: ReadonlyMap<string, ReviewRead>,
  local: ReadonlySet<string> = new Set(),
): { rows: ReviewRow[]; pending: boolean; reached: number } {
  const rows: ReviewRow[] = [];
  let reached = 0;
  for (const candidate of candidates) {
    const read = reads.get(readKey(candidate));
    if (!read) return { rows, pending: false, reached };
    if (read.state === "reading") return { rows, pending: true, reached };
    reached += 1;
    if (read.state === "read" && read.stat && !decided(candidate, read.stat, local))
      rows.push({ ...candidate, stat: read.stat });
  }
  return { rows, pending: false, reached };
}

/// A read stays good while the owner has done nothing since: a finished turn reads the folder again.
export const readKey = (candidate: ReviewCandidate) =>
  `${candidate.key}\u0000${candidate.owner.sessionId}\u0000${candidate.at}`;

/// The candidates to read next: none once `want` rows show (the cursor's place plus `READ_WINDOW`,
/// so a finished read never pulls in more by itself), else the unread ones within `READ_WINDOW` of
/// the last reached candidate. Clean and decided folders show no row, so the reads pass over them.
export function nextReads(
  candidates: readonly ReviewCandidate[],
  reads: ReadonlyMap<string, ReviewRead>,
  shown: { rows: readonly unknown[]; reached: number },
  want = READ_WINDOW,
): ReviewCandidate[] {
  if (shown.rows.length >= want) return [];
  return candidates.slice(0, shown.reached + READ_WINDOW).filter((candidate) => !reads.has(readKey(candidate)));
}

/// The prompt Request changes sends the folder's chat: the person's words, after one line saying
/// which of its changes they are about.
export function changesPrompt(row: ReviewRow, comment: string): string {
  const where = row.owner.branch ? ` on ${row.owner.branch}` : "";
  const files = row.stat.totalFiles === 1 ? "1 file" : `${row.stat.totalFiles} files`;
  // l10n-allow: a prompt the agent reads, not text the person sees.
  return `Review of your changes${where} (${files}, +${row.stat.additions} −${row.stat.deletions}): changes requested.\n\n${comment.trim()}`;
}

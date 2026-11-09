// One index per session list, shared by everything the pane derives from it (Leo, 2026-11-09:
// "Wherever it grows, switch to per-row subscriptions (selectors or signals)"; his rule, 2026-11-04:
// "never ... acceptable ... linear time growth degradation"). A new chat's home read the whole list
// several times for every snapshot: an id map in Waiting on you, the home lists, the inbox and the
// pill each, and a pass for the few chats waiting on the person, with a pull request or working.
// The index holds those: the id map, and the positions of the entries each mark picks. A list made
// from an indexed one by replacing a few entries in place (one session's change, direct.ts
// `sessionChanged`) gets its index from the earlier one, reading only the replaced entries.
import type { AcpmuxSessionEntry } from "./sessionList";

/// Something is pending on the person: acpmux counts an open request, names what the chat waits
/// on, or says the chat is `waiting` (a secret request sets that with neither, hub/secrets.rs). A
/// chat on another computer, or one whose status is unknown, still shows by its indicator alone. A
/// local chat acpmux says is not waiting has nothing pending, whatever its dot last said. A chat
/// acpmux marks `lost` (its machine is unreachable) waits on nobody: no one can answer its ask now,
/// and the sidebar and tab strip mark it as an error, not as waiting (cx-zlox).
export function waitsOnPerson(session: AcpmuxSessionEntry): boolean {
  if (session.indicator === "lost") return false;
  if ((session.pendingPermissions ?? 0) > 0 || session.waitingOn || session.status === "waiting") return true;
  return session.indicator === "input" && (Boolean(session.peer) || session.status === undefined);
}

/// What the index keeps the positions of. Each is a few chats at any list size.
const MARKS = {
  /// Waiting on the person and not archived (needsYou/model.ts `needsYouItems`).
  waiting: (entry: AcpmuxSessionEntry) => !entry.archived && waitsOnPerson(entry),
  /// An open or draft pull request (the home's Ready for review, promptSuggestion.ts).
  openPullRequest: (entry: AcpmuxSessionEntry) =>
    entry.pullRequest?.state === "open" || entry.pullRequest?.state === "draft",
  /// Working, or waiting on the person, by its dot (promptSuggestion.ts `busy`).
  working: (entry: AcpmuxSessionEntry) => entry.indicator === "working" || entry.indicator === "input",
  /// Started by another chat (question/hatModel.ts `childQuestions`, started/startedSessions.ts).
  started: (entry: AcpmuxSessionEntry) => Boolean(entry.startedBy || entry.spawnedBy),
  /// A fork at a turn of another chat (conversation/branches.ts).
  forked: (entry: AcpmuxSessionEntry) => entry.parentId !== undefined && entry.forkSeq !== undefined,
} satisfies Record<string, (entry: AcpmuxSessionEntry) => boolean>;
export type SessionMark = keyof typeof MARKS;
const MARK_NAMES = Object.keys(MARKS) as SessionMark[];

export class SessionIndex {
  /// `positions` is shared by every index derived from this one: their ids sit where they sat.
  constructor(
    readonly sessions: readonly AcpmuxSessionEntry[],
    private readonly positions: ReadonlyMap<string, number>,
    private readonly marked: Readonly<Record<SessionMark, readonly number[]>>,
  ) {}

  /// The entry listed as `id`: the last one when an id is listed twice, as a Map of the list holds.
  get(id: string): AcpmuxSessionEntry | undefined {
    const at = this.positions.get(id);
    return at === undefined ? undefined : this.sessions[at];
  }

  /// No id is listed twice, so an id names one entry.
  get unique(): boolean {
    return this.positions.size === this.sessions.length;
  }

  /// The entries `mark` picks, in list order.
  of(mark: SessionMark): AcpmuxSessionEntry[] {
    return this.marked[mark].map((at) => this.sessions[at]!);
  }

  /// Whether any entry is marked `mark`.
  has(mark: SessionMark): boolean {
    return this.marked[mark].length > 0;
  }

  static build(sessions: readonly AcpmuxSessionEntry[]): SessionIndex {
    const positions = new Map<string, number>();
    const marked = Object.fromEntries(MARK_NAMES.map((mark) => [mark, [] as number[]])) as Record<
      SessionMark,
      number[]
    >;
    sessions.forEach((entry, at) => {
      positions.set(entry.sessionId, at);
      for (const mark of MARK_NAMES) if (MARKS[mark](entry)) marked[mark].push(at);
    });
    return new SessionIndex(sessions, positions, marked);
  }

  /// The index of `sessions`, which is this index's list with the entries at `changed` replaced by
  /// entries of the same ids: O(changed) reads, and a copy of only the marks that moved. Undefined
  /// when an id at one of them is not the one it replaced.
  derive(sessions: readonly AcpmuxSessionEntry[], changed: readonly number[]): SessionIndex | undefined {
    if (sessions.length !== this.sessions.length) return undefined;
    for (const at of changed) if (sessions[at]?.sessionId !== this.sessions[at]?.sessionId) return undefined;
    let marked = this.marked;
    for (const mark of MARK_NAMES) {
      let positions = marked[mark];
      for (const at of changed) {
        const want = MARKS[mark](sessions[at]!);
        const where = sortedIndex(positions, at);
        if (want === (positions[where] === at)) continue;
        positions = want
          ? [...positions.slice(0, where), at, ...positions.slice(where)]
          : [...positions.slice(0, where), ...positions.slice(where + 1)];
      }
      if (positions !== marked[mark]) marked = { ...marked, [mark]: positions };
    }
    return new SessionIndex(sessions, this.positions, marked);
  }
}

/// The first position in ascending `positions` not below `at`.
function sortedIndex(positions: readonly number[], at: number): number {
  let low = 0;
  let high = positions.length;
  while (low < high) {
    const mid = (low + high) >>> 1;
    if (positions[mid]! < at) low = mid + 1;
    else high = mid;
  }
  return low;
}

/// How a list was made from an earlier one: the earlier list with the entries at `at` replaced in
/// place by entries of the same ids (direct.ts `sessionEntryList`).
const madeFrom = new WeakMap<readonly unknown[], { from: readonly unknown[]; at: readonly number[] }>();

/// Records that `to` is `from` with the entries at `at` replaced in place, same ids.
export function noteReplaced<T>(from: readonly T[], to: readonly T[], at: readonly number[]): void {
  madeFrom.set(to, { from, at });
}

/// How many recorded steps back `replacedSince` looks before it gives up.
const STEPS = 64;

/// The positions at which `to` differs from `from`, when `to` was made from it by in-place
/// replacements (`noteReplaced`, up to `STEPS` of them): O(steps), no entry read. Undefined when no
/// such record joins them.
export function replacedSince<T>(from: readonly T[] | undefined, to: readonly T[]): number[] | undefined {
  if (!from) return undefined;
  return replacedFrom(to, (list) => list === from)?.at;
}

/// The nearest list `to` was made from in place (`noteReplaced`, up to `STEPS` back) that `known`
/// accepts, with the positions replaced since: O(steps), no entry read. Undefined when none is.
export function replacedFrom<T>(
  to: readonly T[],
  known: (list: readonly T[]) => boolean,
): { from: readonly T[]; at: number[] } | undefined {
  const at: number[] = [];
  let list: readonly T[] = to;
  for (let steps = 0; !known(list); steps++) {
    const step = madeFrom.get(list);
    if (!step || steps >= STEPS) return undefined;
    at.push(...step.at);
    list = step.from as readonly T[];
  }
  return { from: list, at };
}

const indexes = new WeakMap<readonly AcpmuxSessionEntry[], SessionIndex>();
/// The longest-lived list indexed last, which a list of the same length the pane copied is compared
/// against. A short list (an empty default) never takes its place: indexing one whole costs little.
let lastIndexed: SessionIndex | undefined;
/// More changed entries than this and a list is indexed again from scratch.
const PATCHED = 64;

/// The index of `sessions`, made once per list and shared by every caller. A list made from an
/// indexed one in place (`noteReplaced`) is indexed from it; another of the same length as the list
/// indexed last is compared with it by entry identity (no field read) and indexed from it when only
/// a few entries changed; anything else is indexed whole.
export function sessionIndex(sessions: readonly AcpmuxSessionEntry[]): SessionIndex {
  const kept = indexes.get(sessions);
  if (kept) return kept;
  const made = replacedFrom(sessions, (list) => list !== sessions && indexes.has(list));
  let index = made && indexes.get(made.from)!.derive(sessions, made.at);
  const last = lastIndexed;
  if (!index && last && last.sessions.length === sessions.length) {
    const changed: number[] = [];
    for (let at = 0; at < sessions.length && changed.length <= PATCHED; at++)
      if (sessions[at] !== last.sessions[at]) changed.push(at);
    if (changed.length <= PATCHED) index = last.derive(sessions, changed);
  }
  index ??= SessionIndex.build(sessions);
  indexes.set(sessions, index);
  if (sessions.length > PATCHED) lastIndexed = index;
  return index;
}

/// The first entry listed as `id`, as `sessions.find` gives it: through the list's shared index
/// when no id is listed twice, so a lookup costs no pass over the list. Any list of entries with ids
/// can be indexed: the marks read only fields an entry may lack.
export function findSession<T extends Pick<AcpmuxSessionEntry, "sessionId">>(
  sessions: readonly T[],
  id: string | undefined,
): T | undefined {
  if (id === undefined) return undefined;
  const index = sessionIndex(sessions as unknown as readonly AcpmuxSessionEntry[]);
  return index.unique ? (index.get(id) as T | undefined) : sessions.find((entry) => entry.sessionId === id);
}

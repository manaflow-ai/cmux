// The chats this chat's agent started (acpmux `spawnedBy`, set when its agent runs `acpmux new`),
// as one card in its transcript (StartedSessionCard.tsx), the way Claude Code desktop's Changes
// card lists pull requests: a row for each chat, its title over its status and pull request, and a
// chevron that opens it. Behind the `started-session-cards` experiment, off by default.
//
// The card belongs to the turn its chats were started in (the last prompt made before the child's
// `createdAt`; rows and `createdAt` both come from the daemon's clock) and draws at that turn's end,
// after its reply and before its summary, so it reads after the text that names its chats and
// under the turn's fold line (conversation/turns.ts).
import { experimentArm } from "../../../experiments/experiment";
import type { AcpmuxRow } from "../model";
import { type AcpmuxSessionEntry, type SessionPullRequest, sessionMark } from "../sessionList";
import { sessionIndex } from "../sessionIndex";
import { keptPrefix, noteKeptPrefix, PrefixFlatCache } from "../conversation/prefixFlatMap";
import type { RetryState } from "../subagents/retryState";
import { startedSessionCards } from "./startedSessions.experiment";

/// The row kind of one or more started chats' cards, drawn together where they were started.
export const STARTED_SESSIONS = "startedSessions";

/// Whether started chats draw as cards (the experiment's `on` arm).
export const startedCardsShown = (): boolean => experimentArm(startedSessionCards) === "on";

/// What a started chat's dot says: its turn runs, it waits on the person, its turn failed (or its
/// agent went away), or it is idle.
export type StartedState = "running" | "waiting" | "failed" | "idle";

/// A started chat's pull requests, the way Claude Code's PR rows name one: `repo #N` and its status.
/// `number` and `tone` are those of the one PR acpmux reads the state of (the chat folder's branch
/// PR); without one, the newest recorded URL (`pullRequests`, the `gh pr create` calls acpmux
/// recorded) names it and `tone` is `unknown`. `repo` is the repository's name, from a recorded URL
/// of that number. `count` is every PR the chat opened; `others` names each one but that PR, newest
/// first, so the status line draws every pull request on its own instead of a "+N" count.
export type StartedPullRequests = {
  count: number;
  number: number;
  repo?: string;
  tone: "ready" | "open" | "draft" | "failing" | "merged" | "closed" | "unknown";
  others?: StartedPullRequestName[];
};

/// One pull request a chat opened: `repo #N`, or `#N` when its repository is not known.
export type StartedPullRequestName = { number: number; repo?: string };

export type StartedSession = {
  sessionId: string;
  title: string;
  state: StartedState;
  /// Its last turn ended and nobody has looked at it yet.
  unread?: boolean;
  pullRequests?: StartedPullRequests;
  /// When acpmux made the chat; places its card. Absent from an older acpmux: the card goes last.
  createdAt?: number;
  /// The title is one the chat was given (its title or name), not the first prompt or "New chat"
  /// standing in for one: only then can a reply name it by title.
  named?: boolean;
  /// A sub-session acpmux holds until its chat's running limit has a free slot (`waitsForSlot`).
  waitsForSlot?: boolean;
  /// What its running turn does now (acpmux's doing line, sessionList.ts `doingLine`), for the tray;
  /// only with `doing` asked for, so the transcript's cards do not redraw on each of its calls.
  doing?: string;
  /// The tool part of `doing` (sessionList.ts `doingTool`), with it.
  doingTool?: string;
  /// acpmux's retry of its failed turn while one waits (retryState.ts ``sessionRetry``).
  retry?: RetryState;
  /// The harness it runs (`claude`, `codex`, a profile), whose mark its rows draw.
  harness?: string;
  /// The chat's agent started it with its `start_session` tool (acpmux `startedBy`, hub/subsessions.rs):
  /// one of the chat's own sub-sessions. A lane a coordinator dispatched (`sessions new`, `acpmux new`
  /// from its shell, tagged `mux.parent`) has a lineage parent (`spawnedBy`) but no `startedBy`.
  subsession?: boolean;
  /// When its last turn ended stopped, for a sub-session that is idle: its rows say "Stopped" and
  /// offer Resume (subagents/resumeState.ts ``subsessionResumeRow``).
  stoppedAt?: number;
};

export function startedState(entry: AcpmuxSessionEntry): StartedState {
  const mark = sessionMark(entry, false);
  if (mark === "input" || entry.status === "waiting") return "waiting";
  if (mark === "running" || entry.status === "running") return "running";
  if (mark === "error") return "failed";
  return "idle";
}

const PR_URL = /^https:\/\/github\.com\/([^/\s]+\/[^/\s]+)\/pull\/(\d+)(?:[/?#]|$)/i;

/// The badge of a chat's pull requests: each counted once, whether acpmux recorded its URL, reads it
/// as the folder's branch PR, or both.
export function startedPullRequests(entry: AcpmuxSessionEntry): StartedPullRequests | undefined {
  // `owner/repo#N` (lowercase) to the repository's name as written.
  const recorded = new Map<string, { repo: string; number: number }>();
  for (const url of entry.pullRequestUrls ?? []) {
    const match = PR_URL.exec(url);
    if (!match) continue;
    const number = Number(match[2]);
    const key = `${match[1]!.toLowerCase()}#${number}`;
    if (!recorded.has(key)) recorded.set(key, { repo: match[1]!.split("/")[1]!, number });
  }
  const branch = entry.pullRequest;
  const urls = [...recorded.values()];
  // The branch PR carries a number only: a recorded URL with that number is the same one. When
  // recorded URLs in more than one repository have that number, it is one of them, but which is
  // not known, so the badge names no repository.
  const sameNumber = branch ? urls.filter((pr) => pr.number === branch.number) : [];
  const count = urls.length + (branch && sameNumber.length === 0 ? 1 : 0);
  if (count === 0) return undefined;
  const named = branch ? (sameNumber.length === 1 ? sameNumber[0] : undefined) : urls[urls.length - 1];
  // Every other one, newest first. A branch PR whose number more than one repository has stands
  // for one of them (unnamed), so one of those is left out to keep the count.
  const rest = urls.filter((pr) => pr !== named).reverse();
  const others: StartedPullRequestName[] = sameNumber.length > 1 ? dropOne(rest, branch!.number) : rest;
  return {
    count,
    number: branch?.number ?? named!.number,
    ...(named ? { repo: named.repo } : {}),
    tone: branch ? pullRequestTone(branch) : "unknown",
    ...(others.length > 0 ? { others } : {}),
  };
}

/// What a chat's status line leads with (StartedSessionCard.tsx `SessionStatusLine`): what needs the
/// person (it waits on them, or it failed), else its pull request's status, else that it runs, has
/// new activity, or is done.
export type SessionStatus = "waiting" | "failed" | "running" | "unread" | "done" | PullRequestStatus;
export type PullRequestStatus = Exclude<StartedPullRequests["tone"], "unknown">;

export function sessionStatus(
  state: StartedState,
  unread: boolean | undefined,
  pullRequests: StartedPullRequests | undefined,
): SessionStatus {
  if (state === "waiting" || state === "failed") return state;
  if (pullRequests && pullRequests.tone !== "unknown") return pullRequests.tone;
  if (state === "running") return "running";
  return unread ? "unread" : "done";
}

/// Whether a started chat's row draws a status line under its title: anything but a done chat
/// with no pull request.
export const hasStatusLine = (child: StartedSession): boolean =>
  child.pullRequests !== undefined || sessionStatus(child.state, child.unread, child.pullRequests) !== "done";

function dropOne(prs: StartedPullRequestName[], number: number): StartedPullRequestName[] {
  const at = prs.findIndex((pr) => pr.number === number);
  return at < 0 ? prs : [...prs.slice(0, at), ...prs.slice(at + 1)];
}

function pullRequestTone(pr: SessionPullRequest): StartedPullRequests["tone"] {
  if (pr.state !== "open") return pr.state;
  if (pr.checks === "failing") return "failing";
  if (pr.reviewReady || pr.checks === "passing") return "ready";
  return "open";
}

/// The chats chat `chatId` started, oldest first, but those in `exclude` (an offer's started
/// task, which its suggested tasks card already shows) and archived ones.
export function startedSessions(
  sessions: readonly AcpmuxSessionEntry[],
  chatId: string | undefined,
  { exclude = new Set<string>(), doing = false }: { exclude?: ReadonlySet<string>; doing?: boolean } = {},
): StartedSession[] {
  if (!chatId) return [];
  return sessions
    .filter((entry) => entry.spawnedBy === chatId && !entry.archived && !exclude.has(entry.sessionId))
    .map((entry): StartedSession => {
      const state = startedState(entry);
      const pullRequests = startedPullRequests(entry);
      const title = entry.displayTitle || entry.title || entry.sessionId;
      const named = title === entry.name || title === entry.title?.trim();
      return {
        sessionId: entry.sessionId,
        title,
        state,
        ...(named ? { named: true } : {}),
        ...(state === "idle" && entry.unread ? { unread: true } : {}),
        ...(pullRequests ? { pullRequests } : {}),
        ...(entry.createdAt !== undefined ? { createdAt: entry.createdAt } : {}),
        ...(entry.waitsForSlot ? { waitsForSlot: true } : {}),
        ...(doing && entry.doing ? { doing: entry.doing } : {}),
        ...(doing && entry.doing && entry.doingTool ? { doingTool: entry.doingTool } : {}),
        ...(entry.retry ? { retry: entry.retry } : {}),
        ...(entry.harness ? { harness: entry.harness } : {}),
        ...(entry.startedBy === chatId ? { subsession: true } : {}),
        ...(state === "idle" && entry.startedBy === chatId && entry.stoppedAt !== undefined
          ? { stoppedAt: entry.stoppedAt }
          : {}),
      };
    })
    .sort((a, b) => (a.createdAt ?? Infinity) - (b.createdAt ?? Infinity));
}

/// The chats chat `chatId` started that are not archived, as the session list gives them.
export function spawnedSessions(sessions: readonly AcpmuxSessionEntry[], chatId: string): AcpmuxSessionEntry[] {
  // Among the chats another started only (sessionIndex.ts), not every listed chat.
  return sessionIndex(sessions)
    .of("started")
    .filter((entry) => entry.spawnedBy === chatId && !entry.archived);
}

/// The chats an offer's started tasks name, which their suggested tasks card draws.
export function offerChildren(rows: readonly AcpmuxRow[]): Set<string> {
  const children = new Set<string>();
  for (const row of rows)
    if (row.kind === "sessionOffer")
      for (const offer of row.offers ?? []) if (offer.childSessionId) children.add(offer.childSessionId);
  return children;
}

/// The last card rows drawn, by id, so an unchanged card keeps its object (and its version) from
/// one snapshot to the next: the turn view reshapes only from the first row that changed.
export type StartedCache = Map<string, { key: string; row: AcpmuxRow }>;

/// `rows` with a card row for `children` (``startedSessions``, oldest first) at the end of the turn
/// each was started in: after that turn's last row but its summary. A chat with no `createdAt` (an
/// older acpmux) goes in the last turn's card. `rows` comes back as it is when there are none.
export function withStartedSessions(
  rows: readonly AcpmuxRow[],
  children: readonly StartedSession[],
  cache: StartedCache = new Map(),
): readonly AcpmuxRow[] {
  if (children.length === 0) return rows;
  // Each turn opens with its prompt; rows before the first prompt are a turn of their own. Turn 0
  // starts at row 0, turn `t` at `prompts[t - 1]`. The prompts and the summaries come from passes
  // that read only the rows a snapshot changed (conversation/prefixFlatMap.ts).
  const prompts = promptReads.read(rows).from;
  const turns = prompts.length + 1;
  const startOf = (turn: number) => (turn === 0 ? 0 : prompts[turn - 1]!);
  // One pass: `children` is oldest first, those with no `createdAt` last. Prompts come in the order
  // they were made, so a child's turn (the last from the previous child's on whose prompt was made
  // at or before it) is found by halving, not by a walk of the chat's turns.
  const groups = new Map<number, StartedSession[]>();
  let next = 0;
  for (const child of children) {
    if (child.createdAt === undefined) next = turns - 1;
    else {
      let high = turns - 1;
      while (next < high) {
        const mid = (next + high + 1) >> 1;
        if (rows[startOf(mid)]!.at <= child.createdAt) next = mid;
        else high = mid - 1;
      }
    }
    const group = groups.get(next);
    if (group) group.push(child);
    else groups.set(next, [child]);
  }
  const summaries = summaryReads.read(rows).from;
  // Where each card goes (before the row at that index; `rows.length` is the end), ascending as the
  // turns are, and the card.
  const marks: number[] = [];
  const cards: AcpmuxRow[] = [];
  for (const turn of [...groups.keys()].sort((a, b) => a - b)) {
    const start = startOf(turn);
    const end = turn + 1 < turns ? startOf(turn + 1) : rows.length;
    const summary = summaries[firstAtOrAfter(summaries, start)];
    const at = summary !== undefined && summary < end ? summary : end;
    marks.push(at);
    cards.push(cardRow(groups.get(turn)!, rows[at - 1]?.at ?? rows[at]?.at ?? 0, cache));
  }
  // Only this pass's cards stay cached, so another chat's cards do not pile up.
  const made = new Set(cards.map((card) => card.id));
  for (const id of cache.keys()) if (!made.has(id)) cache.delete(id);
  return placeCards(rows, marks, cards, cache);
}

/// The first index of `sorted` whose value is at least `value` (`sorted.length` when none is).
function firstAtOrAfter(sorted: readonly number[], value: number): number {
  let low = 0;
  let high = sorted.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (sorted[mid]! < value) low = mid + 1;
    else high = mid;
  }
  return low;
}

const ROW: readonly true[] = [true];
const NO_ROW: readonly never[] = [];
/// The prompts that open a turn, by index (one at row 0 opens the first turn, which starts there anyway).
const promptReads = new PrefixFlatCache<AcpmuxRow, true>((row, index) =>
  row.kind === "user" && index > 0 ? ROW : NO_ROW,
);
/// The turn summaries, by index.
const summaryReads = new PrefixFlatCache<AcpmuxRow, true>((row) => (row.kind === "turnSummary" ? ROW : NO_ROW));

/// The last pass that used a cache (one per view: App.tsx keeps one for the chat), its rows and
/// output held weakly so a closed chat leaves no rows here.
const lastPasses = new WeakMap<
  StartedCache,
  {
    marks: readonly number[];
    cards: readonly AcpmuxRow[];
    rows: WeakRef<readonly AcpmuxRow[]>;
    out: WeakRef<readonly AcpmuxRow[]>;
  }
>();

/// `rows` with each card before the row its mark names. Rows change at their tail, so the output
/// starts with the last pass's up to the first row that changed (`keptPrefix`) or the first card
/// that moved or changed, copied, not read, and says so (`noteKeptPrefix`). A streamed token in a
/// chat with started chats then costs the passes after this one (runningTray.ts
/// `withSubagentLines`, turns.ts `turnViewFrom`, the layout) the rows it changed, not a walk of the
/// chat (Leo, 2026-11-12: "even if a chat is long, there should be no percievable difference").
// perf-hot: 1ms agent-chat-token-rows
function placeCards(
  rows: readonly AcpmuxRow[],
  marks: readonly number[],
  cards: readonly AcpmuxRow[],
  cache: StartedCache,
): readonly AcpmuxRow[] {
  const last = lastPasses.get(cache);
  const lastRows = last?.rows.deref();
  const lastOut = last?.out.deref();
  const reuse = last && lastRows && lastOut ? last : undefined;
  const sameCard = (index: number) => marks[index] === reuse!.marks[index] && cards[index] === reuse!.cards[index];
  if (reuse && rows === lastRows && marks.length === reuse.marks.length && marks.every((_, index) => sameCard(index)))
    return lastOut!;
  // `from`: the first row whose output may differ from the last pass's; `marked` cards come before it.
  let from = 0;
  let marked = 0;
  let out: AcpmuxRow[] = [];
  if (reuse) {
    from = keptPrefix(lastRows!, rows);
    while (marked < marks.length && marked < reuse.marks.length && marks[marked]! < from && sameCard(marked))
      marked += 1;
    // A card from `marked` on (either pass's) may differ: the output may differ from where it goes.
    if (marked < reuse.marks.length) from = Math.min(from, reuse.marks[marked]!);
    if (marked < marks.length) from = Math.min(from, marks[marked]!);
    // Rows before `from` and the cards among them are what they were: the last output up to row
    // `from` is this one's.
    out = lastOut!.slice(0, from + marked);
  }
  const kept = out.length;
  let next = from;
  for (let index = marked; index < marks.length; index += 1) {
    for (; next < marks[index]!; next += 1) out.push(rows[next]!);
    out.push(cards[index]!);
  }
  for (; next < rows.length; next += 1) out.push(rows[next]!);
  if (reuse) noteKeptPrefix(out, lastOut!, kept);
  lastPasses.set(cache, { marks, cards, rows: new WeakRef(rows), out: new WeakRef(out) });
  return out;
}

function cardRow(group: StartedSession[], at: number, cache: StartedCache): AcpmuxRow {
  const id = `${STARTED_SESSIONS}-${group[0]!.sessionId}`;
  const key = JSON.stringify(group);
  const kept = cache.get(id);
  if (kept?.key === key && kept.row.at === at) return kept.row;
  const row: AcpmuxRow = { id, version: (kept?.row.version ?? 0) + 1, at, kind: STARTED_SESSIONS, started: group };
  cache.set(id, { key, row });
  return row;
}

/// A session id or title in a reply that names a chat this chat started, for its name chip
/// (StartedSessionChip). Titles shorter than this stay text: a short one ("Fix") is a word.
export const MIN_TITLE_MENTION = 8;

/// The chats a reply can name, longest name first so a title holding another wins.
export type SessionMention = { text: string; sessionId: string; title: string; state: StartedState };

/// A title more than one chat has stays text: which chat it names is not known. Session ids still name theirs.
export function sessionMentions(children: readonly StartedSession[]): SessionMention[] {
  const titled = (child: StartedSession) => child.named && child.title.length >= MIN_TITLE_MENTION;
  const claims = new Map<string, number>();
  for (const child of children) if (titled(child)) claims.set(child.title, (claims.get(child.title) ?? 0) + 1);
  const mentions: SessionMention[] = [];
  for (const child of children) {
    const base = { sessionId: child.sessionId, title: child.title, state: child.state };
    if (titled(child) && claims.get(child.title) === 1) mentions.push({ ...base, text: child.title });
    mentions.push({ ...base, text: child.sessionId });
  }
  return mentions.sort((a, b) => b.text.length - a.text.length);
}

/// `text` cut into plain pieces and the mentions in it, in order. A mention must stand alone: no
/// letter, digit, `-` or `_` right before or after it, and never inside a URL or path (no `/`, `:`,
/// `#`, `?`, `=`, `@`, `~` or `.` before it; no `/`, `:`, `#`, `?`, `=`, `@` or `.x` after it), so a
/// session id in `https://host/sessions/<id>/log` or a longer token stays text.
export function splitMentions(
  text: string,
  mentions: readonly SessionMention[],
): (string | { mention: SessionMention; text: string })[] {
  if (!text || mentions.length === 0) return [text];
  const { pattern, byText } = mentionPattern(mentions);
  const out: (string | { mention: SessionMention; text: string })[] = [];
  let plain = 0;
  for (const match of text.matchAll(pattern)) {
    const mention = byText.get(match[0])!;
    if (match.index > plain) out.push(text.slice(plain, match.index));
    out.push({ mention, text: match[0] });
    plain = match.index + match[0].length;
  }
  if (out.length === 0) return [text];
  if (plain < text.length) out.push(text.slice(plain));
  return out;
}

const patterns = new WeakMap<readonly SessionMention[], { pattern: RegExp; byText: Map<string, SessionMention> }>();
const escapeRegExp = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/// One alternation of every mention, longest first (``sessionMentions`` sorts them), built once a list.
function mentionPattern(mentions: readonly SessionMention[]) {
  let built = patterns.get(mentions);
  if (!built) {
    const byText = new Map<string, SessionMention>();
    for (const mention of mentions) if (!byText.has(mention.text)) byText.set(mention.text, mention);
    const names = [...byText.keys()].sort((a, b) => b.length - a.length).map(escapeRegExp);
    const pattern = new RegExp(
      `(?<![\\p{L}\\p{N}_\\-/:#?=@~.\\\\])(?:${names.join("|")})(?![\\p{L}\\p{N}_\\-/:#?=@\\\\]|\\.[\\p{L}\\p{N}])`,
      "gu",
    );
    built = { pattern, byText };
    patterns.set(mentions, built);
  }
  return built;
}

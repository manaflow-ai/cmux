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
/// of that number. `count` is every PR the chat opened.
export type StartedPullRequests = {
  count: number;
  number: number;
  repo?: string;
  tone: "ready" | "open" | "draft" | "failing" | "merged" | "closed" | "unknown";
};

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
  return {
    count,
    number: branch?.number ?? named!.number,
    ...(named ? { repo: named.repo } : {}),
    tone: branch ? pullRequestTone(branch) : "unknown",
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
      };
    })
    .sort((a, b) => (a.createdAt ?? Infinity) - (b.createdAt ?? Infinity));
}

/// The chats chat `chatId` started that are not archived, as the session list gives them.
export function spawnedSessions(sessions: readonly AcpmuxSessionEntry[], chatId: string): AcpmuxSessionEntry[] {
  return sessions.filter((entry) => entry.spawnedBy === chatId && !entry.archived);
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
  // Each turn opens with its prompt; rows before the first prompt are a turn of their own.
  const starts = [0];
  rows.forEach((row, index) => {
    if (row.kind === "user" && index > 0) starts.push(index);
  });
  // One pass: `children` is oldest first, those with no `createdAt` last.
  const groups = new Map<number, StartedSession[]>();
  let next = 0;
  for (const child of children) {
    if (child.createdAt === undefined) next = starts.length - 1;
    else while (next + 1 < starts.length && rows[starts[next + 1]!]!.at <= child.createdAt) next += 1;
    const turn = next;
    const group = groups.get(turn);
    if (group) group.push(child);
    else groups.set(turn, [child]);
  }
  const out: AcpmuxRow[] = [];
  const made = new Set<string>();
  starts.forEach((start, turn) => {
    const end = starts[turn + 1] ?? rows.length;
    const group = groups.get(turn);
    let at = end;
    if (group)
      for (let index = start; index < end; index++)
        if (rows[index]!.kind === "turnSummary") {
          at = index;
          break;
        }
    for (let index = start; index < end; index++) {
      if (group && index === at) place(group, rows[index - 1]?.at ?? rows[index]!.at);
      out.push(rows[index]!);
    }
    if (group && at === end) place(group, rows[end - 1]?.at ?? 0);
  });
  function place(group: StartedSession[], at: number) {
    const row = cardRow(group, at, cache);
    made.add(row.id);
    out.push(row);
  }
  // Only this pass's cards stay cached, so another chat's cards do not pile up.
  for (const id of cache.keys()) if (!made.has(id)) cache.delete(id);
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

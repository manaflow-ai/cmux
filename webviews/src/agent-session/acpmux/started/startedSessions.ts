// The chats this chat's agent started (acpmux `spawnedBy`, set when its agent runs `acpmux new`),
// as cards in its transcript (StartedSessionCard.tsx), the way Claude Code desktop draws a
// session it started: the child's title, what it does now, its pull requests, a status dot and a
// chevron that opens it. Behind the `started-session-cards` experiment, off by default.
//
// A card sits where its chat was started: before the first row made after the child's
// `createdAt` (rows and `createdAt` both come from the daemon's clock), and never after the end
// of the turn it was started in, so it draws under that turn's fold line (conversation/turns.ts).
import { experimentArm } from "../../../experiments/experiment";
import type { AcpmuxRow } from "../model";
import { type AcpmuxSessionEntry, type SessionPullRequest, sessionMark } from "../sessionList";
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
  /// The latest tool call's title while its turn runs ("Running ss -ltnp"), from the pane's hidden
  /// watch of the chat (offer/offerChildren.ts).
  activity?: string;
  /// Its last turn ended and nobody has looked at it yet.
  unread?: boolean;
  pullRequests?: StartedPullRequests;
  /// When acpmux made the chat; places its card. Absent from an older acpmux: the card goes last.
  createdAt?: number;
  /// The title is one the chat was given (its title or name), not the first prompt or "New chat"
  /// standing in for one: only then can a reply name it by title.
  named?: boolean;
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
  // The branch PR carries a number only: a recorded URL with that number is the same one.
  const same = branch ? urls.find((pr) => pr.number === branch.number) : undefined;
  const count = urls.length + (branch && !same ? 1 : 0);
  if (count === 0) return undefined;
  const named = branch ? same : urls[urls.length - 1];
  return {
    count,
    number: branch?.number ?? named!.number,
    ...(named ? { repo: named.repo } : {}),
    tone: branch ? pullRequestTone(branch) : "unknown",
  };
}

function pullRequestTone(pr: SessionPullRequest): StartedPullRequests["tone"] {
  if (pr.state !== "open") return pr.state;
  if (pr.checks === "failing") return "failing";
  if (pr.reviewReady || pr.checks === "passing") return "ready";
  return "open";
}

/// The chats chat `chatId` started, oldest first, but those in `exclude` (an offer's started
/// task, which its suggested tasks card already shows) and archived ones. `activity` gives a
/// running chat's latest tool call.
export function startedSessions(
  sessions: readonly AcpmuxSessionEntry[],
  chatId: string | undefined,
  {
    exclude = new Set<string>(),
    activity = {},
  }: { exclude?: ReadonlySet<string>; activity?: Readonly<Record<string, string>> } = {},
): StartedSession[] {
  if (!chatId) return [];
  return sessions
    .filter((entry) => entry.spawnedBy === chatId && !entry.archived && !exclude.has(entry.sessionId))
    .map((entry): StartedSession => {
      const state = startedState(entry);
      const pullRequests = startedPullRequests(entry);
      const live = state === "running" ? activity[entry.sessionId] : undefined;
      const title = entry.displayTitle || entry.title || entry.sessionId;
      const named = title === entry.name || title === entry.title?.trim();
      return {
        sessionId: entry.sessionId,
        title,
        state,
        ...(named ? { named: true } : {}),
        ...(live ? { activity: live } : {}),
        ...(state === "idle" && entry.unread ? { unread: true } : {}),
        ...(pullRequests ? { pullRequests } : {}),
        ...(entry.createdAt !== undefined ? { createdAt: entry.createdAt } : {}),
      };
    })
    .sort((a, b) => (a.createdAt ?? Infinity) - (b.createdAt ?? Infinity));
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

/// `rows` with a card row for `children` (``startedSessions``, oldest first) where each was
/// started. `rows` comes back as it is when there are none.
export function withStartedSessions(
  rows: readonly AcpmuxRow[],
  children: readonly StartedSession[],
  cache: StartedCache = new Map(),
): readonly AcpmuxRow[] {
  if (children.length === 0) return rows;
  const out: AcpmuxRow[] = [];
  const made = new Set<string>();
  let next = 0;
  const place = (group: StartedSession[], at: number) => {
    const row = cardRow(group, at, cache);
    made.add(row.id);
    // A turn's rows end with its summary: a chat started before the summary was written but
    // stamped after it still belongs to that turn.
    const end = out.length > 0 && out[out.length - 1]!.kind === "turnSummary" ? out.length - 1 : out.length;
    out.splice(end, 0, row);
  };
  for (const row of rows) {
    const group: StartedSession[] = [];
    while (next < children.length && (children[next]!.createdAt ?? Infinity) < row.at) group.push(children[next++]!);
    if (group.length) place(group, group[0]!.createdAt ?? row.at);
    out.push(row);
  }
  if (next < children.length) {
    const rest = children.slice(next);
    place(rest, rest[0]!.createdAt ?? out[out.length - 1]?.at ?? 0);
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

export function sessionMentions(children: readonly StartedSession[]): SessionMention[] {
  const mentions: SessionMention[] = [];
  for (const child of children) {
    const base = { sessionId: child.sessionId, title: child.title, state: child.state };
    if (child.named && child.title.length >= MIN_TITLE_MENTION) mentions.push({ ...base, text: child.title });
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

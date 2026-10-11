// A message's versions (cx-ncc.61, Claude parity): Edit and resend forks the chat before the prompt
// and sends the edited text in the fork, so each edit is a sibling chat. The prompt the edit replaced
// (in the chat forked from) and the edited prompt (the fork's first own prompt, after its `forked`
// boundary) show < n/m > to step between them. A version is the chat forked from, or one of its
// forks at the same turn, that went past that turn: a fork nobody sent in, a side chat or an
// archived one is not a version.
import type { AcpmuxRow } from "../model";
import type { AcpmuxSessionEntry } from "../sessionList";

/** A prompt's versions: the chats in order (oldest first), and which one this chat is. */
export type MessageBranch = { sessions: string[]; index: number };

const userSeq = (row: AcpmuxRow) => (row.kind === "user" ? Number(row.id.slice("user-".length)) : Number.NaN);

/// The turns a chat holds through `seq`: its turn summaries at or before it.
const turnsThrough = (rows: readonly AcpmuxRow[], seq: number) =>
  rows.filter((row) => row.kind === "turnSummary" && row.seq !== undefined && row.seq <= seq).length;

/// The chat's first prompt after `seq`.
const firstPromptAfter = (rows: readonly AcpmuxRow[], seq: number) =>
  rows.find((row) => userSeq(row) > seq && row.text && !row.failed && !row.pending && !row.queued);

/// The versions at `forkSeq` of `parent`: itself when it went on past that turn, and its forks there
/// that did, oldest first (session ids are time-ordered UUIDv7s). The open chat has its prompt there,
/// so it counts while that prompt's turn still runs.
function versions(
  parent: string,
  forkSeq: number,
  inherited: number,
  sessions: readonly AcpmuxSessionEntry[],
  chat: string,
): string[] {
  const went = (entry: AcpmuxSessionEntry | undefined) =>
    entry?.sessionId === chat || (entry?.turnCount ?? 0) > inherited;
  const forks = sessions
    .filter((entry) => entry.parentId === parent && entry.forkSeq === forkSeq && !entry.side && !entry.archived)
    .filter(went)
    .map((entry) => entry.sessionId)
    .sort();
  return [...(went(sessions.find((entry) => entry.sessionId === parent)) ? [parent] : []), ...forks];
}

/// Each prompt row of the open chat that has another version, with its versions.
export function messageBranches(
  chat: string | undefined,
  rows: readonly AcpmuxRow[],
  sessions: readonly AcpmuxSessionEntry[],
  forkedAtSeq: number | undefined,
): Map<string, MessageBranch> {
  const branches = new Map<string, MessageBranch>();
  if (!chat) return branches;
  const add = (row: AcpmuxRow | undefined, chats: string[]) => {
    const index = chats.indexOf(chat);
    if (row && chats.length > 1 && index >= 0 && !branches.has(row.id))
      branches.set(row.id, { sessions: chats, index });
  };
  // A fork: its first own prompt is a version of the prompt the chat forked from had there.
  const self = sessions.find((entry) => entry.sessionId === chat);
  if (self?.parentId && self.forkSeq !== undefined && forkedAtSeq !== undefined) {
    add(
      firstPromptAfter(rows, forkedAtSeq),
      versions(self.parentId, self.forkSeq, turnsThrough(rows, forkedAtSeq), sessions, chat),
    );
  }
  // The chat's own forks: the prompt after each fork's turn has the fork's prompt as a version.
  const forkSeqs = new Set(
    sessions.filter((entry) => entry.parentId === chat && entry.forkSeq !== undefined).map((entry) => entry.forkSeq!),
  );
  for (const forkSeq of forkSeqs)
    add(firstPromptAfter(rows, forkSeq), versions(chat, forkSeq, turnsThrough(rows, forkSeq), sessions, chat));
  return branches;
}

/// The versions as a string, so the App rebuilds its actions only when they change.
export const branchesKey = (branches: ReadonlyMap<string, MessageBranch>) => JSON.stringify([...branches]);

/// The versions back from `branchesKey`.
export const branchesFromKey = (key: string) => new Map<string, MessageBranch>(JSON.parse(key));

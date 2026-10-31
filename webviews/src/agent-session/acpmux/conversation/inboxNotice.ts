// acpmux's inbox notice (hub/inbox.rs `render`, provenance kind `inbox_notice`): the one prompt
// that tells the agent other agents wrote it, with a line per thread. Its text is written for the
// agent; the transcript draws its threads instead, each as another agent's received line (its
// sender, the thread's label, the newest message's first line, "+N more"), never the person's
// bubble and never the instruction text (Leo, 2026-10-31, on three such bubbles in a row: "isn't
// this rendered pretty terribly? why do we have this like this? why is there so much additional
// text?"). The provenance's `threads` name each thread; a notice logged before they carried a label
// and a preview has them read back from its text. Notices next to each other draw as one group
// (`mergeInboxNotices`), a thread named in two of them once.
import type { AcpmuxRow } from "../model";

/// One message of a thread, as the notice or `_acpmux/inbox_thread` gives it.
export type InboxMessage = { promptId?: string; from: string; at?: number; text: string };

/// One thread of a notice.
export type InboxThread = {
  /// acpmux's thread id: `pr:N`, `topic:T`, `from:SENDER/pr:N` or `from:SENDER`.
  threadId: string;
  /// How it reads: `#N`, the topic, or empty for a sender's own thread.
  label: string;
  /// Its senders, the first first.
  from: string[];
  /// The newest message's sender's session, when it is a chat here.
  fromSession?: string;
  /// The new messages the notice brought.
  count: number;
  /// The newest one's first line.
  preview: string;
  /// It holds a block or a question.
  blocker: boolean;
  /// The new messages' prompt ids: an opened thread shows these.
  promptIds: string[];
  /// The messages whole, oldest first, when the notice holds them.
  messages?: InboxMessage[];
};

export type InboxNotice = { threads: InboxThread[] };

/// The id a thread's line keeps its open state under (incomingOpened.ts): the notice row's and the
/// thread's.
export const inboxThreadKey = (rowId: string, threadId: string) => `${rowId}\u0000${threadId}`;

const text = (value: unknown): string => (typeof value === "string" ? value : "");
const strings = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((v): v is string => typeof v === "string" && v.trim() !== "") : [];

/// How a thread id reads (hub/inbox.rs `label`): `#N` for a pull request, the topic, else nothing.
export function threadLabel(threadId: string): string {
  if (threadId.startsWith("pr:")) return `#${threadId.slice(3)}`;
  if (threadId.startsWith("topic:")) return threadId.slice(6);
  const pr = /\/pr:(\d+)$/.exec(threadId);
  return pr ? `#${pr[1]}` : "";
}

/// The daemon's label without the quotes it puts around a topic for the agent.
const shownLabel = (label: string, threadId: string): string => {
  const quoted = /^"([\s\S]*)"$/.exec(label);
  if (quoted) return quoted[1]!;
  return label === "messages" ? "" : label || threadLabel(threadId);
};

/// A thread's line in the notice's text: `- [blocker] N new in LABEL from A, B: PREVIEW (thread KEY)`,
/// its preview, from a notice logged before the provenance carried one.
function previewFromText(notice: string, threadId: string): string {
  const end = ` (thread ${threadId})`;
  const line = notice.split("\n").find((l) => l.startsWith("- ") && l.endsWith(end));
  if (!line) return "";
  const body = line.slice(2, -end.length);
  const colon = body.indexOf(": ");
  return colon < 0 ? "" : body.slice(colon + 2).trim();
}

/// The notice a prompt is, from its provenance (`threads`) and its text, or undefined when it names
/// no thread.
export function inboxNotice(notice: string, provenance: Record<string, unknown>): InboxNotice | undefined {
  if (!Array.isArray(provenance.threads)) return undefined;
  const threads: InboxThread[] = [];
  for (const part of provenance.threads) {
    if (!part || typeof part !== "object") continue;
    const p = part as Record<string, unknown>;
    const threadId = text(p.threadId);
    if (!threadId) continue;
    const promptIds = strings(p.promptIds);
    const count = typeof p.new === "number" && p.new > 0 ? p.new : Math.max(1, promptIds.length);
    const messages = Array.isArray(p.messages)
      ? p.messages.flatMap((m): InboxMessage[] => {
          const r = m as Record<string, unknown> | null;
          if (!r || typeof r.text !== "string") return [];
          return [
            {
              from: text(r.from),
              text: r.text,
              ...(typeof r.promptId === "string" && { promptId: r.promptId }),
              ...(typeof r.at === "number" && { at: r.at }),
            },
          ];
        })
      : undefined;
    const newest = messages?.at(-1)?.text;
    threads.push({
      threadId,
      label: shownLabel(text(p.label), threadId),
      from: strings(p.from),
      ...(text(p.fromSession) && { fromSession: text(p.fromSession) }),
      count,
      preview: text(p.preview).trim() || previewFromText(notice, threadId) || firstLine(newest ?? ""),
      blocker: p.blocker === true || previewLineBlocks(notice, threadId),
      promptIds,
      ...(messages?.length && { messages }),
    });
  }
  return threads.length ? { threads } : undefined;
}

/// Whether the notice's text tags a thread a blocker (one logged before `blocker` was a part).
const previewLineBlocks = (notice: string, threadId: string): boolean =>
  notice.split("\n").some((l) => l.startsWith("- [blocker] ") && l.includes(`(thread ${threadId})`));

const firstLine = (value: string): string =>
  value
    .split("\n")
    .find((l) => l.trim())
    ?.trim() ?? "";

/// Every message the notice's threads hold, for Find, else their previews.
export function inboxText(notice: InboxNotice): string {
  return notice.threads
    .map((thread) => (thread.messages ? thread.messages.map((m) => m.text).join("\n\n") : thread.preview))
    .join("\n\n");
}

/// The notice's messages and senders: "N messages", and every sender once.
export function inboxCounts(notice: InboxNotice): { messages: number; senders: string[] } {
  const senders: string[] = [];
  let messages = 0;
  for (const thread of notice.threads) {
    messages += thread.count;
    for (const from of thread.from) if (!senders.includes(from)) senders.push(from);
  }
  return { messages, senders };
}

/// Two notices as one: a thread in both once, with the later one's newest message.
export function joinNotices(first: InboxNotice, later: InboxNotice): InboxNotice {
  const threads = first.threads.map((thread) => ({ ...thread }));
  for (const next of later.threads) {
    const at = threads.findIndex((thread) => thread.threadId === next.threadId);
    if (at < 0) {
      threads.push(next);
      continue;
    }
    const held = threads[at]!;
    const joined: InboxThread = {
      ...next,
      label: next.label || held.label,
      from: [...held.from, ...next.from.filter((name) => !held.from.includes(name))],
      count: held.count + next.count,
      blocker: held.blocker || next.blocker,
      promptIds: [...held.promptIds, ...next.promptIds],
    };
    // Whole only when both notices held their messages whole.
    delete joined.messages;
    if (held.messages && next.messages) joined.messages = [...held.messages, ...next.messages];
    threads[at] = joined;
  }
  return { threads };
}

const isNotice = (row: AcpmuxRow) => row.kind === "user" && row.incoming?.kind === "inbox";

/// `rows` with each run of notices next to each other (rows that draw nothing between them) as the
/// first one's row, holding every thread of the run (`joined` names the rest, for Find). The same
/// rows give the same array back; a run gives the same merged row back while its rows hold.
export function mergeInboxNotices(rows: AcpmuxRow[]): AcpmuxRow[] {
  let out: AcpmuxRow[] | undefined;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (!isNotice(row)) {
      out?.push(row);
      continue;
    }
    const run = [row];
    let next = index + 1;
    for (let at = next; at < rows.length; at += 1) {
      const candidate = rows[at]!;
      if (isNotice(candidate)) {
        run.push(candidate);
        next = at + 1;
      } else if (candidate.incoming?.kind !== "hidden") break;
    }
    if (run.length === 1) {
      out?.push(row);
      continue;
    }
    out ??= rows.slice(0, index);
    out.push(mergedRow(run));
    // The rows that draw nothing inside the run go with it; any after it stay.
    index = next - 1;
  }
  return out ?? rows;
}

/// The merged row drawn for a run, by the run's first row object: reused while the run holds the
/// very same row objects, so it never stands in for another chat's rows that share ids.
const merged = new WeakMap<AcpmuxRow, { run: readonly AcpmuxRow[]; row: AcpmuxRow }>();

/// One row for a run of notices, the one drawn before when the run is the same rows.
function mergedRow(run: AcpmuxRow[]): AcpmuxRow {
  const first = run[0]!;
  const held = merged.get(first);
  if (held && held.run.length === run.length && held.run.every((row, i) => row === run[i])) return held.row;
  const joined = run.slice(1).map((row) => row.id);
  const version = run.reduce((sum, row) => sum + row.version, 0);
  let notice = (first.incoming as { kind: "inbox"; notice: InboxNotice }).notice;
  for (const row of run.slice(1)) notice = joinNotices(notice, (row.incoming as { notice: InboxNotice }).notice);
  const row = { ...first, version, joined, text: inboxText(notice), incoming: { kind: "inbox" as const, notice } };
  merged.set(first, { run, row });
  return row;
}

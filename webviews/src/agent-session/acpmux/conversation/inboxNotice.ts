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
import { keptPrefix, noteKeptPrefix } from "./prefixFlatMap";
import { withoutRelayEnvelope, withoutRelayHead } from "./relayEnvelope";
import { bareSender, relayAddress, senderRecord, senderUnverified, type SenderRecord } from "./senderIdentity";
import type { SentFrom } from "./sentFromHarness";

/// Who sent a message, as acpmux records it (`sender`, prompt_provenance.rs
/// `sender_record_with_auth`): the sending chat's id when acpmux proved it, and the name it gave
/// (its label, never cut). A chip opens the sender by these, never by `from`, the line's display
/// text (Leo, 2026-11-07: clicking a sender "just fundamentally doesn't load"). The record's
/// verification and harness read as `unverified` and `harness` beside it.
export type SenderRef = { session?: string; label?: string };

/// One message of a thread, as the notice or `_acpmux/inbox_thread` gives it. `from` is the bare
/// name (senderIdentity.ts); `unverified` when acpmux could not verify who sent it, `harness` the
/// sender's family from its record.
export type InboxMessage = {
  promptId?: string;
  from: string;
  sender?: SenderRef;
  at?: number;
  text: string;
  unverified?: true;
  harness?: string;
};

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
  /// The newest message's sender, as acpmux recorded it (its label and session).
  sender?: SenderRef;
  /// The newest message's sender's harness family (`claude`, `codex`, ...), when acpmux bound it
  /// (prompt_provenance.rs `fromHarness`; cmux#30247) or its sender record names it: its line draws
  /// that harness's mark.
  fromHarness?: string;
  /// acpmux could not verify the newest message's sender (its record's `verification`, or an older
  /// acpmux's suffix on its name): the line's subtle marker, never words in the name.
  unverified?: true;
  /// The new messages the notice brought.
  count: number;
  /// The newest one's first line.
  preview: string;
  /// The newest one whole, when the notice held no messages but acpmux sent it under its bound
  /// (hub/inbox.rs `newest`): the line draws it at once, with no read that grows it.
  newest?: string;
  /// It holds a block or a question.
  blocker: boolean;
  /// The new messages' prompt ids: an opened thread shows these.
  promptIds: string[];
  /// The messages whole, oldest first, when the notice holds them.
  messages?: InboxMessage[];
  /// Where each message says it came from, by its prompt id (`sender_claim`, sentFromHarness.ts):
  /// a sender chip under it.
  sentFrom?: Record<string, SentFrom>;
};

export type InboxNotice = { threads: InboxThread[] };

/// The id a thread's line keeps its open state under (incomingOpened.ts): the notice row's and the
/// thread's.
export const inboxThreadKey = (rowId: string, threadId: string) => `${rowId}\u0000${threadId}`;

const text = (value: unknown): string => (typeof value === "string" ? value : "");
/// The session and lookup label of acpmux's sender record (senderIdentity.ts `senderRecord`): a
/// relayed sender's label is its relay address (senderIdentity.ts `relayAddress`), since the
/// record's label is then only the name the sender declared (`--from`), which a local namesake may
/// hold too (cmux#38642 review).
const senderRef = (record: SenderRecord | undefined): SenderRef | undefined => {
  if (!record) return undefined;
  const label = relayAddress(record.relay) ?? record.label;
  return record.session || label
    ? { ...(record.session && { session: record.session }), ...(label && { label }) }
    : undefined;
};

/// The key a sender's chat is asked for by: its session id, else the name it gave, else `from`.
export const senderKey = (from: string, sender: SenderRef | undefined): string =>
  sender?.session ?? sender?.label ?? from.trim();

const strings = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((v): v is string => typeof v === "string" && v.trim() !== "") : [];

/// How a thread id reads (hub/inbox.rs `label`): `#N` for a pull request, the topic, else nothing.
export function threadLabel(threadId: string): string {
  if (threadId.startsWith("pr:")) return `#${threadId.slice(3)}`;
  if (threadId.startsWith("topic:")) return threadId.slice(6);
  const pr = /\/pr:(\d+)$/.exec(threadId);
  return pr ? `#${pr[1]}` : "";
}

/// The daemon's label without the quotes it puts around a topic for the agent, nor the unverified
/// suffix an older acpmux put on a self-named sender's thread.
const shownLabel = (written: string, threadId: string): string => {
  const label = bareSender(written).name;
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
    const held = Array.isArray(p.messages) ? inboxMessages(p.messages) : undefined;
    const newest = held?.at(-1)?.text;
    const senders = strings(p.from).map(bareSender);
    const record = senderRecord(p.sender);
    const sender = senderRef(record);
    const harness = text(p.fromHarness) || record?.harness || held?.at(-1)?.harness;
    const unverified = senderUnverified(record, senders.at(-1)?.declared ?? false) || held?.at(-1)?.unverified === true;
    // The thread's flag is its newest sender's (its record, or an older acpmux's suffix on its
    // `from`), which acpmux may say only on the thread: that message is marked too, so its row and
    // the group's hover show it (laneNoticeBatches.ts, MessageGroupHover.tsx).
    const messages =
      unverified && held?.length && !held.at(-1)!.unverified
        ? [...held.slice(0, -1), { ...held.at(-1)!, unverified: true as const }]
        : held;
    threads.push({
      threadId,
      label: shownLabel(text(p.label), threadId),
      from: [...new Set(senders.map((sender) => sender.name).filter(Boolean))],
      ...(text(p.fromSession) && { fromSession: text(p.fromSession) }),
      ...(sender && { sender }),
      ...(harness && { fromHarness: harness }),
      ...(unverified && { unverified: true as const }),
      count,
      preview:
        withoutRelayHead(text(p.preview).trim()) ||
        withoutRelayHead(previewFromText(notice, threadId)) ||
        firstLine(newest ?? ""),
      blocker: p.blocker === true || previewLineBlocks(notice, threadId),
      promptIds,
      ...(messages?.length && { messages }),
      ...(!messages?.length && typeof p.newest === "string" && { newest: withoutRelayEnvelope(p.newest) }),
    });
  }
  return threads.length ? { threads } : undefined;
}

/// A thread's messages as acpmux records them (a notice's `messages`, `_acpmux/inbox_thread`), each
/// without the broker label it came in (relayEnvelope.ts): every one is another agent's. An opened
/// thread's sender is its `fromName`, the name alone; its `from` is the agent's words for it.
export function inboxMessages(records: unknown[]): InboxMessage[] {
  return records.flatMap((m): InboxMessage[] => {
    const r = m as Record<string, unknown> | null;
    if (!r || typeof r.text !== "string") return [];
    const name = bareSender(text(r.from));
    const record = senderRecord(r.sender);
    const sender = senderRef(record);
    return [
      {
        from: text(r.fromName) || name.name,
        ...(sender && { sender }),
        text: withoutRelayEnvelope(r.text),
        ...(senderUnverified(record, name.declared) && { unverified: true as const }),
        ...(record?.harness && { harness: record.harness }),
        ...(typeof r.promptId === "string" && { promptId: r.promptId }),
        ...(typeof r.at === "number" && { at: r.at }),
      },
    ];
  });
}

/// Whether the notice's text tags a thread a blocker (one logged before `blocker` was a part).
const previewLineBlocks = (notice: string, threadId: string): boolean =>
  notice.split("\n").some((l) => l.startsWith("- [blocker] ") && l.includes(`(thread ${threadId})`));

const firstLine = (value: string): string =>
  value
    .split("\n")
    .find((l) => l.trim())
    ?.trim() ?? "";

/// Every message the notice's threads hold, for Find, else their newest messages or previews.
export function inboxText(notice: InboxNotice): string {
  return notice.threads
    .map((thread) =>
      thread.messages ? thread.messages.map((m) => m.text).join("\n\n") : (thread.newest ?? thread.preview),
    )
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

/// A thread's newest sender: its newest message's, else its last named.
const newestFrom = (thread: InboxThread): string => thread.messages?.at(-1)?.from ?? thread.from.at(-1) ?? "";

/// A thread's sender as acpmux identified it: its session id, else its record's label, from the
/// thread's record, else its newest message's own (acpmux may name it only there).
const senderIdentity = (thread: InboxThread) => {
  const record = thread.sender ?? thread.messages?.at(-1)?.sender;
  return { session: record?.session || thread.fromSession, label: record?.label };
};

/// Whether the later thread's newest sender is the earlier one's own chat, not only its name: the
/// later one names no identity of its own, or both name the same session (else, when neither names
/// one, the same record). Two chats can share a name or a label (cmux#38642, cmux#38791 reviews), so
/// a matching one alone never lends one's record, session, family or unverified mark to the other.
const sameSender = (held: InboxThread, next: InboxThread): boolean => {
  if (newestFrom(held) !== newestFrom(next)) return false;
  const a = senderIdentity(held);
  const b = senderIdentity(next);
  if (!b.session && !b.label) return true;
  if (a.session || b.session) return a.session === b.session;
  return !!a.label && a.label === b.label;
};

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
    // The later notice names the newest sender; when it is the earlier one's own chat and says less
    // of it, the earlier one's record, session, family and unverified mark still hold. A record of
    // its own (the thread's, or its newest message's) says whether that sender is verified, so the
    // earlier mark never reaches a newest message its own notice did not mark (cmux#38642 review).
    if (sameSender(held, next)) {
      if (!next.sender && held.sender) joined.sender = held.sender;
      if (!next.fromSession && held.fromSession) joined.fromSession = held.fromSession;
      if (!next.fromHarness && held.fromHarness) joined.fromHarness = held.fromHarness;
      const ownRecord = next.sender ?? next.messages?.at(-1)?.sender;
      if (!next.unverified && held.unverified && !ownRecord) joined.unverified = held.unverified;
    }
    if (held.sentFrom || next.sentFrom) joined.sentFrom = { ...held.sentFrom, ...next.sentFrom };
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
/// Rows change at their tail, so a call reads again only the rows after the last run that closed
/// before the first row that changed (`keptPrefix`): a tool call arriving in a long chat costs its
/// own rows, not a read of every row's kind (bench/transcript-replay.bench.ts, god log).
export function mergeInboxNotices(rows: AcpmuxRow[]): AcpmuxRow[] {
  const last = lastMerge?.rows.deref();
  const lastOut = lastMerge?.out.deref();
  let start = 0;
  let out: AcpmuxRow[] | undefined;
  let swallowed: number[] = [];
  if (last && lastOut && lastMerge) {
    if (last === rows) return lastOut;
    // Back from the first changed row to one that ends any run (neither a notice nor a row that
    // draws nothing): no run crosses it, so what came before it merged as it did last time.
    start = keptPrefix(last, rows);
    while (start > 0 && (isNotice(rows[start - 1]!) || rows[start - 1]!.incoming?.kind === "hidden")) start -= 1;
    // The rows each earlier run took in (the source index after the run, and how many rows the
    // merge has dropped by then) say where the kept rows' items end in the last output.
    swallowed = lastMerge.swallowed.filter((at) => at <= start);
    const left = swallowed.length ? lastMerge.dropped[swallowed.length - 1]! : 0;
    if (left > 0) out = lastOut.slice(0, start - left);
  }
  const kept = swallowed.length;
  const dropped: number[] = lastMerge && last ? lastMerge.dropped.slice(0, kept) : [];
  for (let index = start; index < rows.length; index += 1) {
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
    swallowed.push(next);
    dropped.push((dropped.at(-1) ?? 0) + next - index - 1);
    // The rows that draw nothing inside the run go with it; any after it stay.
    index = next - 1;
  }
  const result = out ?? rows;
  if (out && lastOut) noteKeptPrefix(out, lastOut, start - (dropped[kept - 1] ?? 0));
  lastMerge = { rows: new WeakRef(rows), out: new WeakRef(result), swallowed, dropped };
  return result;
}

/// The last call's rows and output, held weakly (a closed chat leaves nothing here), with each run
/// it merged: `swallowed[i]` the index after the run, `dropped[i]` how many rows the merge had left
/// out by then.
let lastMerge:
  | { rows: WeakRef<AcpmuxRow[]>; out: WeakRef<AcpmuxRow[]>; swallowed: number[]; dropped: number[] }
  | undefined;

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

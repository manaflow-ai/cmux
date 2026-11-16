// Waiting on you (queue/QueueScreen.tsx): every ask that waits on the person, across agents and
// machines, from acpmux's `_acpmux/review_queue`, highest score first. Approvals, plan approvals,
// questions and pull requests; code changes waiting on review stay the Review queue's job
// (review/), which this page links to. Nothing here is a store of its own: an item leaves as soon
// as acpmux stops reporting it, and an answer goes the way Needs you sends it (needsYou/).
import { questionAnswers, type NeedsYouAnswer, type NeedsYouItem } from "../needsYou/model";
import { questionFromPermission, type AgentQuestion } from "../question/model";

export const QUEUE_METHOD = "_acpmux/review_queue";
export const VERDICT_METHOD = "_acpmux/review_verdict";
export const AUDIT_METHOD = "_acpmux/audit";
/// How many items one read asks for (acpmux's own default).
export const QUEUE_LIMIT = 200;

export type QueueKind = "approval" | "plan" | "question" | "pr";
export type QueueOption = { optionId: string; name: string; kind?: string };

/// One item of `_acpmux/review_queue` (spec: the wedge's `QueueItem`).
export type QueueItem = {
  id: string;
  kind: QueueKind;
  sessionId: string;
  /// The peer machine that holds the chat; absent for this machine.
  host?: string;
  title: string;
  harness?: string;
  vendor?: string;
  workspaceId?: string;
  ask: string;
  detail?: string;
  /// When it was asked (epoch ms).
  at: number;
  impact: number;
  impactReasons: string[];
  score: number;
  permissionId?: string;
  turnId?: string;
  options: QueueOption[];
  /// The raw permission request of a question, as acpmux recorded it.
  question?: unknown;
  prUrl?: string;
};

/// `total` counts the items acpmux had before its `limit` cut (as many as `items` from an acpmux
/// that does not say).
export type QueueReply = { items: QueueItem[]; peersOmitted: string[]; now: number; total: number };

const KINDS: readonly QueueKind[] = ["approval", "plan", "question", "pr"];
const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
const num = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
const record = (value: unknown) =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;

/// Reads acpmux's answer; an item missing what it needs to be shown is dropped, never drawn half.
export function readQueue(value: unknown, fallbackNow = Date.now()): QueueReply {
  const body = record(value);
  const now = num(body?.now) ?? fallbackNow;
  const items: QueueItem[] = [];
  for (const raw of Array.isArray(body?.items) ? body.items : []) {
    const item = readItem(raw, now);
    if (item) items.push(item);
  }
  const peersOmitted = (Array.isArray(body?.peersOmitted) ? body.peersOmitted : []).flatMap((peer) => {
    const name = text(peer) ?? text(record(peer)?.name);
    return name ? [name] : [];
  });
  const total = Math.max(num(body?.total) ?? 0, items.length);
  return { items: sortQueue(rowIds(items)), peersOmitted, now, total };
}

/// A row's id for the page. acpmux names a pull request `pr:{url}` in every chat and on every
/// machine that has it, and two machines can each have an ask `acpmux:p1`: a pull request's row
/// and another machine's row are told apart by machine and chat. The same item always gets the
/// same id, however many others share acpmux's, so a draft or an answer never moves to another row.
function rowIds(items: QueueItem[]): QueueItem[] {
  return items.map((item) =>
    item.kind === "pr" || item.host ? { ...item, id: `${item.id}@${item.host ?? ""}/${item.sessionId}` } : item,
  );
}

function readItem(raw: unknown, now: number): QueueItem | undefined {
  const item = record(raw);
  const id = text(item?.id);
  const kind = item?.kind as QueueKind;
  const sessionId = text(item?.sessionId);
  if (!item || !id || !KINDS.includes(kind) || (!sessionId && kind !== "pr")) return undefined;
  const at = num(item.at) ?? now - (num(item.ageMs) ?? 0);
  const options = (Array.isArray(item.options) ? item.options : []).flatMap((option) => {
    const value = record(option);
    const optionId = text(value?.optionId);
    if (!optionId) return [];
    const kindText = text(value?.kind);
    return [{ optionId, name: text(value?.name) ?? optionId, ...(kindText ? { kind: kindText } : {}) }];
  });
  const optional = (key: string) => {
    const value = text(item[key]);
    return value ? { [key]: value } : {};
  };
  return {
    id,
    kind,
    sessionId: sessionId ?? "",
    title: text(item.title) ?? sessionId ?? id,
    ask: text(item.ask) ?? "",
    at,
    impact: num(item.impact) ?? 0,
    impactReasons: (Array.isArray(item.impactReasons) ? item.impactReasons : []).filter(
      (reason): reason is string => typeof reason === "string" && reason.length > 0,
    ),
    score: num(item.score) ?? 0,
    options,
    ...optional("host"),
    ...optional("harness"),
    ...optional("vendor"),
    ...optional("workspaceId"),
    ...optional("detail"),
    ...optional("permissionId"),
    ...optional("turnId"),
    ...optional("prUrl"),
    ...(item.question !== undefined && item.question !== null ? { question: item.question } : {}),
  };
}

/// Highest score first; equal scores, the one asked first; then by id, so the order never shuffles.
export function sortQueue(items: readonly QueueItem[]): QueueItem[] {
  return [...items].sort((a, b) => b.score - a.score || a.at - b.at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/// What a plain key does on the list (a modified key is the app's). Answers are not plain keys:
/// a permission answer needs the person's click or the app's permission shortcut (Allow Once,
/// Deny), which the host counts as theirs and the page gets as an event (QueueScreen.tsx), never a
/// keystroke the page saw.
export type QueueCommand = { kind: "move"; step: 1 | -1 } | { kind: "open" } | { kind: "export" };

export type QueueKey = { key: string; metaKey?: boolean; ctrlKey?: boolean; altKey?: boolean; shiftKey?: boolean };

export function queueCommand(event: QueueKey): QueueCommand | undefined {
  if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return undefined;
  switch (event.key) {
    case "j":
    case "ArrowDown":
      return { kind: "move", step: 1 };
    case "k":
    case "ArrowUp":
      return { kind: "move", step: -1 };
    case "Enter":
      return { kind: "open" };
    case "x":
    case "e":
      return { kind: "export" };
    default:
      return undefined;
  }
}

/// The question a `question` item asks, read the way the chat's card reads it.
export function itemQuestion(item: QueueItem): AgentQuestion | undefined {
  if (item.question === undefined || !item.permissionId) return undefined;
  try {
    return questionFromPermission({
      permissionId: item.permissionId,
      session: item.sessionId,
      request: item.question as never,
    });
  } catch {
    return undefined;
  }
}

/// The one-click answers an item takes in place: its exact `allow_once` and `reject_once` options,
/// for an approval or a plan, the tool permissions the host answers for a chat this page does not
/// show (`chat.asks.answer`). Never a lasting grant in their place: an `allow_always` or a
/// `reject_always` is answered in the chat, where the person sees what it keeps deciding, so an
/// item with neither once option shows none here and opens its chat. A pull request takes its
/// verdict instead. A one-pick question takes its choices, which the host sends as its card would
/// (homeInboxModel.ts `replyElsewhere`); a longer one is answered in its chat, where its card shows
/// the whole question. An ask on another machine is answered there.
export function queueAnswers(item: QueueItem): NeedsYouAnswer[] {
  if (item.kind === "pr" || item.host) return [];
  if (item.kind === "question") {
    const question = itemQuestion(item);
    return question ? questionAnswers(question) : [];
  }
  const allow = item.options.find((option) => option.kind === "allow_once");
  const deny = item.options.find((option) => option.kind === "reject_once");
  return [
    ...(allow ? [{ id: allow.optionId, label: allow.name, tone: "allow" as const }] : []),
    ...(deny ? [{ id: deny.optionId, label: deny.name, tone: "deny" as const }] : []),
  ];
}

/// The item as Needs you's shape, so its answer goes through Needs you's own path
/// (needsYou/useNeedsYou.ts `answerParams` and `answerAnotherChat`), never a copy of it.
export function needsYouItem(item: QueueItem): NeedsYouItem {
  const question = item.kind === "question" ? itemQuestion(item) : undefined;
  return {
    id: item.id,
    kind: item.kind === "question" ? "decision" : "approval",
    sessionId: item.sessionId,
    ask: item.ask,
    ...(item.detail ? { detail: item.detail } : {}),
    who: { name: item.title, ...(item.harness ? { harness: item.harness } : {}), chief: item.harness === "chief" },
    at: item.at,
    answers: queueAnswers(item),
    ...(item.permissionId ? { permissionId: item.permissionId } : {}),
    ...(item.turnId ? { turnId: item.turnId } : {}),
    ...(question ? { question } : {}),
  };
}

/// Why an item ranks where it does, from acpmux's `impactReasons` (`name` or `name:value`). Only the
/// reasons the page can say in words; an unknown one is left out rather than shown raw.
export type QueueReason =
  | { kind: "blocksTurn" }
  | { kind: "queuedPrompts"; n: number }
  | { kind: "costUsd"; usd: number }
  | { kind: "subsessions"; n: number }
  | { kind: "age" };

export function queueReasons(item: QueueItem): QueueReason[] {
  return item.impactReasons.flatMap((reason): QueueReason[] => {
    const [name, value] = reason.split(":", 2);
    const n = value === undefined ? NaN : Number(value);
    switch (name) {
      case "blocksTurn":
        return [{ kind: "blocksTurn" }];
      case "queuedPrompts":
        return Number.isFinite(n) && n > 0 ? [{ kind: "queuedPrompts", n }] : [];
      case "costUsd":
        return Number.isFinite(n) && n > 0 ? [{ kind: "costUsd", usd: n }] : [];
      case "subsessions":
        return Number.isFinite(n) && n > 0 ? [{ kind: "subsessions", n }] : [];
      case "age":
        return [{ kind: "age" }];
      default:
        return [];
    }
  });
}

/// The review verdict a pull request item sends (`_acpmux/review_verdict`): acpmux records it
/// on this Mac for the chat that made the PR, so it needs that chat, and another machine's PR has
/// none here (its row opens its chat instead). The wire says `accepted` or `changes`.
export function verdictParams(
  item: QueueItem,
  verdict: "accept" | "changes",
  comment?: string,
): Record<string, unknown> | undefined {
  if (item.kind !== "pr" || !item.prUrl || !item.sessionId || item.host) return undefined;
  return {
    prUrl: item.prUrl,
    sessionId: item.sessionId,
    verdict: verdict === "accept" ? "accepted" : "changes",
    ...(comment?.trim() ? { comment: comment.trim() } : {}),
  };
}

/// Whether acpmux (or the host relaying to it) does not know the method yet: an older daemon.
export function isOlderDaemon(error: unknown): boolean {
  const code = record(error)?.code;
  if (code === -32601 || code === "-32601" || code === "transport.method_refused") return true;
  const message = error instanceof Error ? error.message : text(record(error)?.message);
  return typeof message === "string" && /method not found|unknown method/i.test(message);
}

/// The audit trail's entries, oldest first, page after page (`next` is the cursor of the page
/// after), at most `maxPages` reads: the array `acpmux audit export` prints.
export async function auditEntries(
  read: (params: Record<string, unknown>) => Promise<unknown>,
  maxPages: number,
): Promise<unknown[]> {
  const entries: unknown[] = [];
  // acpmux's cursor is the last entry's `seq`, a number; it goes back exactly as it came.
  let cursor: string | number | undefined;
  for (let page = 0; page < maxPages; page++) {
    const reply = record(await read(cursor === undefined ? {} : { cursor }));
    const list = reply?.entries;
    if (Array.isArray(list)) entries.push(...list);
    const next = reply?.next;
    cursor =
      (typeof next === "string" && next) || (typeof next === "number" && Number.isFinite(next)) ? next : undefined;
    if (cursor === undefined) break;
  }
  return entries;
}

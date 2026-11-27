// Your asks (asks/AsksScreen.tsx): what the person typed into chats on this machine, from acpmux's
// Ask ledger (`_acpmux/asks`, cmux-tui hub/asks). acpmux decides what is an ask, its id, its pull
// requests and its status; this file only reads the reply into rows.

export const ASKS_METHOD = "_acpmux/asks";
/// How many asks one read asks for (acpmux's own default).
export const ASKS_LIMIT = 200;

export type AskStatus = "open" | "pr" | "merged";
export type AskPrState = "open" | "merged" | "closed";
export type AskKind = "ask" | "decision";

export type AskPr = { url: string; repo?: string; number?: number; state: AskPrState };

export type Ask = {
  id: string;
  ts: number;
  text: string;
  harness: string;
  sessionId: string;
  sessionTitle?: string;
  host: string;
  kind: AskKind;
  status: AskStatus;
  prs: AskPr[];
};

export type AsksReply = { asks: Ask[]; next?: number; nextId?: string };

const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
const num = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;

const STATUSES: readonly AskStatus[] = ["open", "pr", "merged"];
const PR_STATES: readonly AskPrState[] = ["open", "merged", "closed"];
const KINDS: readonly AskKind[] = ["ask", "decision"];

function readPr(value: unknown): AskPr | undefined {
  const pr = record(value);
  const url = text(pr?.url);
  if (!pr || !url) return undefined;
  const state = PR_STATES.find((s) => s === pr.state) ?? "open";
  const repo = text(pr.repo);
  const number = num(pr.number);
  return { url, state, ...(repo ? { repo } : {}), ...(number !== undefined ? { number } : {}) };
}

function readAsk(value: unknown): Ask | undefined {
  const ask = record(value);
  const id = text(ask?.id);
  const sessionId = text(ask?.sessionId);
  const ts = num(ask?.ts);
  if (!ask || !id || !sessionId || ts === undefined) return undefined;
  const title = text(ask.sessionTitle);
  return {
    id,
    ts,
    text: text(ask.text) ?? "",
    harness: text(ask.harness) ?? "",
    sessionId,
    host: text(ask.host) ?? "",
    kind: KINDS.find((kind) => kind === ask.kind) ?? "ask",
    status: STATUSES.find((s) => s === ask.status) ?? "open",
    prs: Array.isArray(ask.prs) ? ask.prs.map(readPr).filter((pr): pr is AskPr => pr !== undefined) : [],
    ...(title ? { sessionTitle: title } : {}),
  };
}

/// Only an explicit daemon opt-in exposes the Labs surface; older replies fail closed.
export function askLedgerEnabled(value: unknown): boolean {
  return record(value)?.enabled === true;
}

/// acpmux's `_acpmux/asks` reply; anything it does not recognise is left out.
export function readAsks(value: unknown): AsksReply {
  const reply = record(value);
  const asks = Array.isArray(reply?.asks) ? reply.asks.map(readAsk).filter((a): a is Ask => a !== undefined) : [];
  const next = num(reply?.next);
  return {
    asks,
    ...(next !== undefined ? { next } : {}),
    ...(text(reply?.nextId) ? { nextId: text(reply?.nextId)! } : {}),
  };
}

/// The row's one line: the ask's first line that has words.
export function askLine(ask: Ask): string {
  return (
    ask.text
      .split("\n")
      .find((line) => line.trim())
      ?.trim() ?? ""
  );
}

/// A pull request chip's label: `#N`, else the URL's last part.
export function prLabel(pr: AskPr): string {
  if (pr.number !== undefined) return `#${pr.number}`;
  return pr.url.split("/").pop() ?? pr.url;
}

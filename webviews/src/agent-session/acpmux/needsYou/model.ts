// Needs you (Leo 2026-10-20): one list of every open ask, so no agent has to restate "still waiting
// on you". It holds approvals, decisions, verify-this asks and held messages from the Chief, its
// subagents and every other agent chat. Nothing here is a store of its own: every item is derived
// from what acpmux already reports (asks.ts tracks its pending permission requests, the same ones
// `acpmux pending` lists and the Feed bridge posts; the session list's `indicator` and
// `pendingPermissions`; the open chat's agent pair holds), so an ask leaves the list as soon as
// acpmux says it was answered, wherever it was answered.
//
// The item is the shared shape (plans/cmux-next/needs-you.md): the header's pinned list draws it,
// the Feed keys the same prompt `acpmux:<permissionId>` (its dedupe key), and an agent points at an
// item with `cmux://needs-you/<permissionId>` (links.ts) instead of restating it.
import type { AcpmuxAgentPair, AcpmuxPermission, AcpmuxRow, QueuedPrompt } from "../model";
import { questionSummary, type AgentQuestion } from "../question/model";
import type { AcpmuxSessionEntry } from "../sessionList";

/// What the ask wants: an allow or deny of a tool (`approval`), a pick among choices
/// (`decision`), a check of the agent's work (`verify`), messages acpmux holds between two agents
/// (`held`), or a chat that waits on the person with no ask the page can read (`input`: a chat on
/// another computer, whose prompts reach this pane only as its session's indicator).
export type NeedsYouKind = "approval" | "decision" | "verify" | "held" | "input";

/// A one-click answer: an allow, a deny, one of a question's choices, or a held pair's Resume.
export type NeedsYouAnswer = { id: string; label: string; tone: "allow" | "deny" | "choice" };

/// Who asked: the chat's title and agent, whether it is the Chief, and the chat that started it.
export type NeedsYouWho = { name: string; harness?: string; chief: boolean; via?: string };

export type NeedsYouItem = {
  /// Stable while the ask is open: `acpmux:<permissionId>` (the Feed's key for the same prompt),
  /// `held:<sessionId>:<peer>` or `chat:<sessionId>`.
  id: string;
  kind: NeedsYouKind;
  sessionId: string;
  /// The ask on one line.
  ask: string;
  /// More about the ask, when it says more than its line: a description, or the command it would run.
  detail?: string;
  /// `detail` is a command (drawn as code).
  command?: boolean;
  who: NeedsYouWho;
  /// When it was asked, as near as acpmux tells (epoch ms).
  at?: number;
  /// One-click answers; none when the ask needs more than a click (several questions, free text).
  answers: NeedsYouAnswer[];
  permissionId?: string;
  /// The turn the ask was made in, for Go to source (`#turn-<turnId>`).
  turnId?: string;
  /// A held pair's other agent (its acpmux peer id), which Resume names, and how many messages
  /// acpmux holds; `ask` is that agent's name.
  peer?: string;
  held?: number;
  /// A guest's held prompt (`awaitingOwner`), which Review opens on its card; `ask` is its text.
  promptId?: string;
  question?: AgentQuestion;
};

/// A permission request acpmux reports pending (asks.ts), with when the page first saw it.
export type WatchedAsk = { sessionId: string; permission: AcpmuxPermission; at: number };

export type NeedsYouInput = {
  sessions: readonly AcpmuxSessionEntry[];
  asks: readonly WatchedAsk[];
  /// The open chat and its rows: its agent pair holds are read from them, and its guests' held
  /// prompts from its queue, answered here only where acpmux serves Approve (`queueApproval`).
  open?: { sessionId?: string; rows: readonly AcpmuxRow[]; queue?: readonly QueuedPrompt[]; queueApproval?: boolean };
};

/// The Feed's key for a prompt (CmuxNextApp AcpmuxPermissionFeedBridge `dedupe_key`).
export const askItemId = (permissionId: string) => `acpmux:${permissionId}`;

/// A question's choices as one-click answers: only a single question with one pick among at most
/// four choices; anything else opens at its source.
export const QUICK_CHOICES = 4;

/// Verify-this asks: an ask that starts by asking the person to check something.
const VERIFY = /^\s*(?:please\s+|can you\s+|could you\s+)?(?:verify|check|confirm|review|test|try|look at)\b/i;

/// The Chief asks through its own harness (`chief`), and its chats are named for it.
const CHIEF_NAME = /^chief\b/i;

export function needsYouItems(input: NeedsYouInput): NeedsYouItem[] {
  const byId = new Map(input.sessions.map((session) => [session.sessionId, session]));
  const items: NeedsYouItem[] = [];
  const asked = new Set<string>();
  for (const watched of input.asks) {
    const session = byId.get(watched.sessionId);
    // Another computer's chat is answered there: it is one `input` item below, with no answers.
    if (session?.archived || session?.peer) continue;
    asked.add(watched.sessionId);
    items.push(askItem(watched, session, byId));
  }
  if (input.open?.sessionId) {
    const session = byId.get(input.open.sessionId);
    for (const pair of heldPairs(input.open.rows)) {
      // The chat's held messages are what it waits on: no second, vaguer item for it below.
      asked.add(input.open.sessionId);
      items.push({
        id: `held:${input.open.sessionId}:${pair.peer}`,
        kind: "held",
        sessionId: input.open.sessionId,
        ask: pair.peerName,
        detail: pair.held[0]?.text,
        who: who(session, input.open.sessionId, byId),
        answers: [{ id: "resume", label: "resume", tone: "allow" }],
        peer: pair.peer,
        held: pair.held.length,
      });
    }
    // A guest's prompt waits for the owner as a permission ask does (design/chat-multiplayer.md).
    for (const entry of input.open.queueApproval ? (input.open.queue ?? []) : []) {
      if (!entry.awaitingOwner) continue;
      asked.add(input.open.sessionId);
      items.push({
        id: `guest:${input.open.sessionId}:${entry.id}`,
        kind: "held",
        sessionId: input.open.sessionId,
        ask: entry.prompt,
        who: who(session, input.open.sessionId, byId),
        // Never approved from here: a preview is not what the owner approves. Review goes to the
        // held card, which shows the whole message and has Approve (QueuedMessageCard.tsx).
        answers: [{ id: "review", label: "review", tone: "choice" }],
        promptId: entry.id,
      });
    }
  }
  // A chat that waits on the person with no ask read here (a chat on another computer, a grouped
  // request, or one whose ask is still being read): one item, so it is never missing from the list.
  for (const session of input.sessions) {
    if (asked.has(session.sessionId) || session.archived || !waitsOnPerson(session)) continue;
    items.push({
      id: `chat:${session.sessionId}`,
      ...waitingAsk(session),
      sessionId: session.sessionId,
      who: who(session, session.sessionId, byId),
      ...(session.updatedAt ? { at: session.updatedAt } : {}),
      answers: [],
    });
  }
  // Newest first, as every list of chats in the pane; an ask without a time last.
  return items.sort((a, b) => (b.at ?? 0) - (a.at ?? 0));
}

/// Something is pending on the person: acpmux counts an open request, names what the chat waits
/// on, or says the chat is `waiting` (a secret request sets that with neither, hub/secrets.rs). A
/// chat on another computer, or one whose status is unknown, still shows by its indicator alone. A
/// local chat acpmux says is not waiting has nothing pending, whatever its dot last said. A chat
/// acpmux marks `lost` (its machine is unreachable) waits on nobody: no one can answer its ask now,
/// and the sidebar and tab strip mark it as an error, not as waiting (cx-zlox).
function waitsOnPerson(session: AcpmuxSessionEntry): boolean {
  if (session.indicator === "lost") return false;
  if ((session.pendingPermissions ?? 0) > 0 || session.waitingOn || session.status === "waiting") return true;
  return session.indicator === "input" && (Boolean(session.peer) || session.status === undefined);
}

/// What a chat whose ask is not read here waits on, as acpmux names it: a question by its first
/// prompt (`waitingPrompt`), a permission as a permission. Never the chat's last message
/// (`preview`): that is what the agent said, not what it asks (Leo 2026-10-21). An empty ask
/// reads as its kind's line (NeedsYou.tsx `askText`).
function waitingAsk(session: AcpmuxSessionEntry): Pick<NeedsYouItem, "kind" | "ask"> {
  const waiting = session.waitingOn;
  if (waiting?.on === "question") {
    const ask = waiting.prompt ?? "";
    return { kind: VERIFY.test(ask) ? "verify" : "decision", ask };
  }
  if (waiting?.on === "permission") return { kind: "approval", ask: "" };
  return { kind: "input", ask: "" };
}

function askItem(
  watched: WatchedAsk,
  session: AcpmuxSessionEntry | undefined,
  byId: ReadonlyMap<string, AcpmuxSessionEntry>,
): NeedsYouItem {
  const { permission } = watched;
  const question = permission.question;
  const ask = question
    ? questionSummary(question)
    : (permission.title ?? permission.description ?? permission.kind ?? "");
  const detail = question ? undefined : (permission.command ?? permission.description);
  const kind: NeedsYouKind = VERIFY.test(ask) ? "verify" : question ? "decision" : "approval";
  const asker = who(session, watched.sessionId, byId);
  return {
    id: askItemId(permission.permissionId),
    kind,
    sessionId: watched.sessionId,
    ask,
    ...(detail && detail !== ask ? { detail, ...(permission.command ? { command: true } : {}) } : {}),
    who: question?.source.harness === "chief" ? { ...asker, chief: true } : asker,
    at: watched.at,
    answers: question ? questionAnswers(question) : permissionAnswers(permission),
    permissionId: permission.permissionId,
    ...(permission.turnId ? { turnId: permission.turnId } : {}),
    ...(question ? { question } : {}),
  };
}

/// Allow once and deny once: the answers a click may give. An allow that lasts (always, for the
/// chat) is the card's to give, where its scope is spelled out.
function permissionAnswers(permission: AcpmuxPermission): NeedsYouAnswer[] {
  const allow = permission.options.find((option) => option.kind === "allow_once" && option.allow);
  const deny = permission.options.find((option) => option.kind === "reject_once" && !option.allow);
  return [
    ...(allow ? [{ id: allow.id, label: allow.name, tone: "allow" as const }] : []),
    ...(deny ? [{ id: deny.id, label: deny.name, tone: "deny" as const }] : []),
  ];
}

function questionAnswers(question: AgentQuestion): NeedsYouAnswer[] {
  const [item, ...more] = question.items;
  if (!item || more.length > 0 || item.multiSelect || item.options.length > QUICK_CHOICES) return [];
  return item.options.map((option) => ({ id: option.id, label: option.label, tone: "choice" as const }));
}

/// The open chat's agent pairs that still hold messages for the person to release.
export function heldPairs(rows: readonly AcpmuxRow[]): AcpmuxAgentPair[] {
  const pairs = new Map<string, AcpmuxAgentPair>();
  for (const row of rows) {
    const pair = row.kind === "agentPair" ? row.agentPair : undefined;
    if (!pair) continue;
    // A later row for the same peer replaces an earlier one (a re-pause takes over what it held).
    if (pair.resumed || pair.held.length === 0) pairs.delete(pair.peer);
    else pairs.set(pair.peer, pair);
  }
  return [...pairs.values()];
}

function who(
  session: AcpmuxSessionEntry | undefined,
  sessionId: string,
  byId: ReadonlyMap<string, AcpmuxSessionEntry>,
): NeedsYouWho {
  const name = session?.displayTitle ?? session?.name ?? sessionId;
  const parent = session?.spawnedBy ? byId.get(session.spawnedBy) : undefined;
  return {
    name,
    ...(session?.harness ? { harness: session.harness } : {}),
    chief: isChief(session),
    ...(parent ? { via: parent.displayTitle ?? parent.name ?? parent.sessionId } : {}),
  };
}

const isChief = (session: AcpmuxSessionEntry | undefined) =>
  session?.harness === "chief" || CHIEF_NAME.test(session?.name ?? "");

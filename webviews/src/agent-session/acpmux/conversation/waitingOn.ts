// What the chat waits on the person for, when it waits on them (App.tsx): the folder's trust
// question, a permission ask, a secret or a question card above the composer. The running turn's
// line says so ("Waiting for you: trust this folder?") instead of "Thinking" or a ticking clock,
// so nobody waits on an agent that waits on them (Leo, 2026-10-21: "Thinking" that never ends while
// the trust question sat out of sight). With no ask open, a turn whose model has said nothing
// since its prompt past acpmux's `silentTurnMs` (direct.ts `silentTurn`) says "No response from the
// model yet", so a stalled model is not "Thinking" forever.
import { createContext } from "react";
import type { FolderTrustAsk } from "../useFolderTrustAsk";
import type { StringKey } from "../i18n";
import type { PermissionGroupState } from "../permissions/protocol";

export type WaitingOn = "trust" | "trustRemote" | "permission" | "secret" | "question" | "model";

export const WaitingOnContext = createContext<WaitingOn | undefined>(undefined);

/// The line's words for each wait.
export const WAITING_LABEL: Record<WaitingOn, StringKey> = {
  trust: "turn.waiting.trust",
  trustRemote: "turn.waiting.trustRemote",
  permission: "turn.waiting.permission",
  secret: "turn.waiting.secret",
  question: "turn.waiting.question",
  model: "turn.waiting.model",
};

/// The first ask the person must answer, in the order the bottom stack shows them: the trust
/// question holds every other ask (useFolderTrustAsk.ts `holdsAsks`), so it comes first. A model
/// that has said nothing comes after every ask: what the person can answer goes first.
export function waitingOn(asks: {
  trust?: FolderTrustAsk;
  permission: boolean;
  secret: boolean;
  question: boolean;
  model?: boolean;
}): WaitingOn | undefined {
  const trust = asks.trust?.state;
  if (trust === "ask" || trust === "failed") return "trust";
  if (trust === "remote") return "trustRemote";
  if (asks.permission) return "permission";
  if (asks.secret) return "secret";
  if (asks.question) return "question";
  if (asks.model) return "model";
  return undefined;
}

/// The chat's asks as App.tsx has them, read as the line's wait. Only asks the stack draws count
/// (the trust question holds the others out of it), only open ones (answered permission groups stay
/// listed as receipts; a card at work asks nothing), and trust only while no turn runs: it holds
/// new prompts, not a turn already going. acpmux sends an agent's question (AskUserQuestion, Codex
/// user input) as a permission request, so the pending ask that carries one is a question, never
/// "allow this?" (Leo, 2026-10-21, in a Full access chat).
export function chatWaitsOn(chat: {
  trust?: FolderTrustAsk;
  /// The trust question holds the chat's other asks (useFolderTrustAsk.ts `holdsAsks`).
  holdsAsks: boolean;
  /// Trust's read is in flight or its answer blocks Send (`blocked`): a secret waits behind it.
  trustBlocks: boolean;
  isWorking: boolean;
  /// The pending ask on the chat's own card, when one is open: a tool's permission, or a question
  /// when it carries one (direct.ts `permissionFromMessage`, question/model.ts `questionFromPermission`).
  individualPermission?: { question?: unknown };
  permissionGroups?: readonly { state: PermissionGroupState }[];
  secret: boolean;
  cards: readonly { state: string }[];
  /// The running turn's model has said nothing since its prompt (`AcpmuxSnapshot.silentTurn`).
  silent?: boolean;
}): WaitingOn | undefined {
  const shown = !chat.holdsAsks;
  const ask = chat.individualPermission;
  const asksQuestion = ask?.question !== undefined;
  return waitingOn({
    trust: chat.isWorking ? undefined : chat.trust,
    permission:
      shown &&
      ((ask !== undefined && !asksQuestion) ||
        (chat.permissionGroups ?? []).some((group) => group.state === "pending" || group.state === "collecting")),
    secret: shown && !chat.trustBlocks && chat.secret,
    question: shown && (asksQuestion || chat.cards.some((card) => card.state === "ask")),
    model: chat.isWorking && chat.silent === true,
  });
}

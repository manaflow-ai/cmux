// What the chat waits on the person for, when it waits on them (App.tsx): the folder's trust
// question, a permission ask, a secret or a question card above the composer. The running turn's
// line says so ("Waiting for you: trust this folder?") instead of "Thinking" or a ticking clock,
// so nobody waits on an agent that waits on them (Leo, 2026-10-21: "Thinking" that never ends while
// the trust question sat out of sight).
import { createContext } from "react";
import type { FolderTrustAsk } from "../useFolderTrustAsk";
import type { StringKey } from "../i18n";

export type WaitingOn = "trust" | "trustRemote" | "permission" | "secret" | "question";

export const WaitingOnContext = createContext<WaitingOn | undefined>(undefined);

/// The line's words for each wait.
export const WAITING_LABEL: Record<WaitingOn, StringKey> = {
  trust: "turn.waiting.trust",
  trustRemote: "turn.waiting.trustRemote",
  permission: "turn.waiting.permission",
  secret: "turn.waiting.secret",
  question: "turn.waiting.question",
};

/// The first ask the person must answer, in the order the bottom stack shows them: the trust
/// question holds every other ask (useFolderTrustAsk.ts `holdsAsks`), so it comes first.
export function waitingOn(asks: {
  trust?: FolderTrustAsk;
  permission: boolean;
  secret: boolean;
  question: boolean;
}): WaitingOn | undefined {
  const trust = asks.trust?.state;
  if (trust === "ask" || trust === "failed") return "trust";
  if (trust === "remote") return "trustRemote";
  if (asks.permission) return "permission";
  if (asks.secret) return "secret";
  if (asks.question) return "question";
  return undefined;
}

// The chat's tool cards the host pushes (`toolCards`, CmuxNextAgentPane AgentPaneToolCard): cards a
// cmux tool raises in this chat, such as an agent's Move to Cloud ask (cmuxterm-hq#1874 slice 5).
// The host owns each card and its text (already in the user's language); the page draws it and
// sends a click back as `chat.toolCard.respond {id, action}`, which the host takes only with a real
// gesture in the pane. A module store, so a push that arrives before the chat mounts is kept.
import { useSyncExternalStore } from "react";

export type ToolCardAction = { id: string; title: string; hint?: string };
export type ToolCard = { id: string; state: "ask" | "working" | "failed"; text: string; actions: ToolCardAction[] };

const STATES = new Set<string>(["ask", "working", "failed"]);
let cards: ToolCard[] = [];
const listeners = new Set<() => void>();

function readAction(value: unknown): ToolCardAction[] {
  const action = value as Partial<ToolCardAction> | null;
  if (!action || typeof action.id !== "string" || typeof action.title !== "string") return [];
  return [{ id: action.id, title: action.title, ...(typeof action.hint === "string" ? { hint: action.hint } : {}) }];
}

/// Replaces the cards from a host push; anything malformed is dropped.
export function setToolCards(value: unknown): void {
  cards = Array.isArray(value)
    ? value.flatMap((item): ToolCard[] => {
        const card = item as Partial<ToolCard> | null;
        if (!card || typeof card.id !== "string" || typeof card.text !== "string" || !STATES.has(String(card.state)))
          return [];
        const actions = Array.isArray(card.actions) ? card.actions.flatMap(readAction) : [];
        return [{ id: card.id, state: card.state as ToolCard["state"], text: card.text, actions }];
      })
    : [];
  for (const listener of listeners) listener();
}

function current(): ToolCard[] {
  return cards;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useToolCards(): ToolCard[] {
  return useSyncExternalStore(subscribe, current, current);
}

declare global {
  interface Window {
    /// The old host's script for the `toolCards` event (CmuxNextAgentPane AgentPaneToolCard).
    cmuxAcpmuxToolCards?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxToolCards = setToolCards;

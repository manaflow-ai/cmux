// The chat's tool cards the host pushes (`toolCards`, CmuxNextAgentPane AgentPaneToolCard): cards a
// cmux tool raises in this chat, such as an agent's Move to Cloud ask (cmuxterm-hq#1874 slice 5).
// The host owns each card and its text (already in the user's language); the page draws it and
// sends a click back as `chat.toolCard.respond {id, action}`, which the host takes only with a real
// gesture in the pane. A card may have one text field (`input`, a secret the person types): its value
// goes as `value`, only with a button that `submitsInput`, and is never kept here. A module store, so
// a push that arrives before the chat mounts is kept.
import { useSyncExternalStore } from "react";

export type ToolCardAction = { id: string; title: string; hint?: string; submitsInput?: boolean };
export type ToolCardInput = { placeholder: string; secure: boolean; maxBytes: number };
export type ToolCard = {
  id: string;
  state: "ask" | "working" | "done" | "failed";
  text: string;
  actions: ToolCardAction[];
  input?: ToolCardInput;
};

const STATES = new Set<string>(["ask", "working", "done", "failed"]);
let cards: ToolCard[] = [];
const listeners = new Set<() => void>();

function readAction(value: unknown): ToolCardAction[] {
  const action = value as Partial<ToolCardAction> | null;
  if (!action || typeof action.id !== "string" || typeof action.title !== "string") return [];
  return [
    {
      id: action.id,
      title: action.title,
      ...(typeof action.hint === "string" ? { hint: action.hint } : {}),
      ...(action.submitsInput === true ? { submitsInput: true } : {}),
    },
  ];
}

function readInput(value: unknown): ToolCardInput | undefined {
  const input = value as Partial<ToolCardInput> | null | undefined;
  if (!input || typeof input.placeholder !== "string" || typeof input.secure !== "boolean") return undefined;
  if (typeof input.maxBytes !== "number" || !Number.isInteger(input.maxBytes) || input.maxBytes <= 0) return undefined;
  return { placeholder: input.placeholder, secure: input.secure, maxBytes: input.maxBytes };
}

/// Replaces the cards from a host push; anything malformed is dropped.
export function setToolCards(value: unknown): void {
  cards = Array.isArray(value)
    ? value.flatMap((item): ToolCard[] => {
        const card = item as Partial<ToolCard> | null;
        if (!card || typeof card.id !== "string" || typeof card.text !== "string" || !STATES.has(String(card.state)))
          return [];
        const actions = Array.isArray(card.actions) ? card.actions.flatMap(readAction) : [];
        const input = readInput(card.input);
        return [
          {
            id: card.id,
            state: card.state as ToolCard["state"],
            text: card.text,
            actions,
            ...(input ? { input } : {}),
          },
        ];
      })
    : [];
  for (const listener of listeners) listener();
}

/// The cards kept now (the hook's snapshot; tests read it directly).
export function currentToolCards(): ToolCard[] {
  return cards;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useToolCards(): ToolCard[] {
  return useSyncExternalStore(subscribe, currentToolCards, currentToolCards);
}

declare global {
  interface Window {
    /// The old host's script for the `toolCards` event (CmuxNextAgentPane AgentPaneToolCard).
    cmuxAcpmuxToolCards?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxToolCards = setToolCards;

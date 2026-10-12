import React from "react";
import type { ToolCard } from "./toolCardStore";

/// The chat's tool cards, each one quiet line among the chat's permission asks, above the composer:
/// what a cmux tool asks or is doing, in the host's words, and its buttons. A click goes to the
/// host (`onAnswer`); the card changes when the host pushes its next state.
export function ToolCards({ cards, onAnswer }: { cards: ToolCard[]; onAnswer(card: string, action: string): void }) {
  return (
    <>
      {cards.map((card) => (
        <div key={card.id} className="acpmux-trust-ask acpmux-tool-card" data-state={card.state} aria-live="polite">
          <span className="acpmux-trust-ask-text" title={card.text}>
            {card.text}
          </span>
          {card.actions.map((action) => (
            <button
              key={action.id}
              type="button"
              className="acpmux-trust-ask-action"
              title={action.hint}
              onClick={() => onAnswer(card.id, action.id)}
            >
              {action.title}
            </button>
          ))}
        </div>
      ))}
    </>
  );
}

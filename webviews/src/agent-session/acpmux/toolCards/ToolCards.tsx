import React, { useState } from "react";
import type { ToolCard } from "./toolCardStore";

/// The chat's tool cards, each one quiet line among the chat's permission asks, above the composer:
/// what a cmux tool asks or is doing, in the host's words, and its buttons. A click goes to the
/// host (`onAnswer`); the card changes when the host pushes its next state.
export function ToolCards({
  cards,
  onAnswer,
}: {
  cards: ToolCard[];
  onAnswer(card: string, action: string, value?: string): void;
}) {
  return (
    <>
      {cards.map((card) => (
        <ToolCardRow key={card.id} card={card} onAnswer={onAnswer} />
      ))}
    </>
  );
}

/// One card. A card with a field (a secret the person types) keeps what was typed only in this
/// row's state, sends it only with a button that submits the field, and clears it on that click.
function ToolCardRow({
  card,
  onAnswer,
}: {
  card: ToolCard;
  onAnswer(card: string, action: string, value?: string): void;
}) {
  const [value, setValue] = useState("");
  const input = card.state === "ask" ? card.input : undefined;
  const submit = input ? card.actions.find((action) => action.submitsInput) : undefined;
  // The host takes at most `maxBytes` UTF-8 bytes; `maxLength` counts UTF-16 units, so check bytes here.
  const fits = !input || new TextEncoder().encode(value).length <= input.maxBytes;
  const send = (action: string, submitsInput: boolean | undefined) => {
    if (submitsInput && (!value || !fits)) return;
    const typed = submitsInput ? value : undefined;
    if (input) setValue("");
    onAnswer(card.id, action, typed);
  };
  return (
    <form
      className="acpmux-trust-ask acpmux-tool-card"
      data-state={card.state}
      aria-live="polite"
      onSubmit={(event) => {
        event.preventDefault();
        if (submit) send(submit.id, true);
      }}
    >
      <span className="acpmux-trust-ask-text">{card.text}</span>
      {input && (
        <input
          className="acpmux-tool-card-input"
          type={input.secure ? "password" : "text"}
          value={value}
          placeholder={input.placeholder}
          aria-label={input.placeholder}
          maxLength={input.maxBytes}
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="off"
          spellCheck={false}
          onChange={(event) => setValue(event.target.value)}
        />
      )}
      {card.actions.map((action) => (
        <button
          key={action.id}
          type={action.submitsInput && input ? "submit" : "button"}
          className="acpmux-trust-ask-action"
          /* tooltip-allow: the button names the action; the tooltip is its scope, shown nowhere else */
          title={action.hint}
          disabled={action.submitsInput === true && (!input || !value || !fits)}
          onClick={action.submitsInput && input ? undefined : () => send(action.id, action.submitsInput)}
        >
          {action.title}
        </button>
      ))}
    </form>
  );
}

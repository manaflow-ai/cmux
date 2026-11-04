import React, { useState } from "react";
import { Notice, type NoticeAction, type NoticeKind } from "../../../ui/Notice";
import { Spinner } from "../conversation/icons";
import type { ToolCard } from "./toolCardStore";

/// The chat's tool cards among the chat's permission asks, above the composer: what a cmux tool asks
/// or is doing, in the host's words, and its buttons, drawn as the shared notice (ui/Notice.tsx,
/// leo-workspace design/notifications.md). A click goes to the host (`onAnswer`); the card changes
/// when the host pushes its next state. An action the host marks `check` is the card's checkmark
/// ("Ask me first"): a click toggles it through the host, which pushes the new state.
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

/// The notice kind of a card's state: an ask asks, a stopped run is an error, the rest are status.
export function toolCardKind(state: ToolCard["state"]): NoticeKind {
  return state === "ask" ? "ask" : state === "failed" ? "error" : "toast";
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
  const kind = toolCardKind(card.state);
  const check = card.actions.find((action) => action.check !== undefined);
  const buttons = card.actions.filter((action) => action !== check);
  // A stopped run's Retry leads (the error kind's rule); the rest keep the host's order.
  const retry = kind === "error" ? buttons.find((action) => action.id === "retry") : undefined;
  const actions: NoticeAction[] = buttons
    .filter((action) => action !== retry)
    .map((action) => ({
      id: action.id,
      label: action.title,
      hint: action.hint,
      submit: action.submitsInput === true && input !== undefined,
      disabled: action.submitsInput === true && (!input || !value || !fits),
      onSelect: () => send(action.id, action.submitsInput),
    }));
  return (
    <form
      className="acpmux-tool-card"
      data-state={card.state}
      onSubmit={(event) => {
        event.preventDefault();
        if (submit) send(submit.id, true);
      }}
    >
      <Notice
        kind={kind}
        message={card.text}
        leading={card.state === "working" ? <Spinner size={14} /> : undefined}
        retry={retry && { label: retry.title, hint: retry.hint, onRetry: () => send(retry.id, false) }}
        actions={actions}
        check={
          check && {
            label: check.title,
            hint: check.hint,
            checked: check.check === true,
            onCheckedChange: () => send(check.id, false),
          }
        }
      >
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
      </Notice>
    </form>
  );
}

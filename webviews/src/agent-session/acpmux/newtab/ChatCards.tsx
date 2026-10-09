import React from "react";
import { AgentMark } from "../NewTabPage";
import type { ChatCard } from "./screenModel";
import { useNt } from "./strings";

/// "Chats" with "All Chats >" and the recent chats as cards: age, title and the last reply, or
/// the state when the chat needs the user or dropped. Routines join as a second tab once the
/// automations ops exist (hidden until then, plans/cmux-next/new-tab.md section 4).
export function ChatCards({
  cards,
  variant = "cards",
  onOpen,
  onShowAll,
}: {
  cards: ChatCard[];
  /// Cards in a grid, or one line per chat (the Threads and Console templates).
  variant?: "cards" | "list";
  onOpen(sessionId: string): void;
  onShowAll(): void;
}) {
  const nt = useNt();
  return (
    <section className="nt-chats" aria-label={nt("sections")}>
      <header className="nt-chats-head">
        <span className="nt-chats-tab is-selected">{nt("chats")}</span>
        <button type="button" className="nt-chats-all" onClick={() => onShowAll()}>
          {nt("allChats")}
          <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
            <path d="m6 3.5 4.5 4.5L6 12.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
          </svg>
        </button>
      </header>
      {cards.length === 0 ? (
        <p className="nt-chats-empty">{nt("noChats")}</p>
      ) : (
        <div className="nt-cards" data-variant={variant}>
          {cards.map((card) => (
            <button
              key={card.sessionId}
              type="button"
              className="nt-card"
              data-state={card.state}
              aria-label={nt("card.open", { title: card.title })}
              onClick={() => onOpen(card.sessionId)}
            >
              <span className="nt-card-meta">
                <AgentMark harness={card.harness} />
                <span className="nt-card-age">{card.age}</span>
              </span>
              <span className="nt-card-title">{card.title}</span>
              <span className="nt-card-message">
                {card.state === "idle" ? (card.message ?? "") : nt(`card.${card.state}`)}
              </span>
            </button>
          ))}
        </div>
      )}
    </section>
  );
}

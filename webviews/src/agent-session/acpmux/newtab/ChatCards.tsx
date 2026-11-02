import React, { useRef, useState } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import { pressToOpen } from "../../../ui/pressToOpen";
import { useT } from "../i18n";
import { AgentMark } from "../NewTabPage";
import { useListMotion } from "./listMotion";
import type { ChatCard } from "./screenModel";
import { useNt } from "./strings";
import "./chatCardsLoading.css";

/// "Chats" with "All Chats >" and the recent chats as cards: age, title and the last reply, or
/// the state when the chat needs the user or dropped. Routines join as a second tab once the
/// automations ops exist (hidden until then, plans/cmux-next/new-tab.md section 4).
export function ChatCards({
  cards,
  pending = false,
  variant = "cards",
  title,
  onOpen,
  onOpenInTerminal,
  onShowAll,
}: {
  cards: ChatCard[];
  /** The first session-list read has not settled; populated cards stay visible. */
  pending?: boolean;
  /// Cards in a grid, or one line per chat (the Threads and Console templates).
  variant?: "cards" | "list";
  /// The section's name; "Chats" when unset.
  title?: string;
  onOpen(sessionId: string): void;
  /// The card menu's Open in Terminal; omitted when the chat cannot open there.
  onOpenInTerminal?(sessionId: string): void;
  /// "All Chats >"; omitted when the page shows All chats itself.
  onShowAll?(): void;
}) {
  const nt = useNt();
  const t = useT();
  const list = useRef<HTMLDivElement>(null);
  /// Parents whose child list is open; each starts collapsed.
  const [open, setOpen] = useState<ReadonlySet<string>>(() => new Set());
  const toggle = (id: string) =>
    setOpen((was) => {
      const next = new Set(was);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  const row = (card: ChatCard, child: boolean) => (
    <button
      key={card.sessionId}
      type="button"
      className="nt-card"
      data-state={card.state}
      data-child={child ? "" : undefined}
      aria-label={nt("card.open", { title: card.title })}
      {...pressToOpen(() => onOpen(card.sessionId))}
    >
      <span className="nt-card-meta">
        <AgentMark harness={card.harness} />
        <span className="nt-card-age">{card.age}</span>
      </span>
      <span className="nt-card-title">{card.title}</span>
      {(card.state !== "idle" || card.message) && (
        <span className="nt-card-message">
          {card.state === "idle"
            ? card.message
            : card.state === "failed"
              ? t("header.failed")
              : nt(`card.${card.state}`)}
        </span>
      )}
    </button>
  );
  useListMotion(
    list,
    ".nt-card-host > .nt-card, .nt-card-family > .nt-card",
    // A chat keeps its row when acpmux's session takes its device chat's slot (one active chat).
    cards.map((card) => (card.chatId ? `chat:${card.chatId}` : card.sessionId)),
  );
  return (
    <section className="nt-chats" aria-label={nt("sections")}>
      <header className="nt-chats-head">
        <span className="nt-chats-tab is-selected">{title ?? nt("chats")}</span>
        {onShowAll && (
          <button type="button" className="nt-chats-all" onClick={() => onShowAll()}>
            {nt("allChats")}
            <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
              <path
                d="m6 3.5 4.5 4.5L6 12.5"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
              />
            </svg>
          </button>
        )}
      </header>
      {cards.length === 0 && pending ? (
        <div className="nt-cards nt-cards-loading" data-variant={variant} aria-busy="true" aria-label={nt("chats")}>
          {Array.from({ length: 3 }, (_, index) => (
            <div key={index} className="nt-card" aria-hidden="true">
              <span className="nt-card-meta">
                <svg className="nt-card-placeholder nt-card-placeholder-icon" width="16" height="16" />
                <span className="nt-card-age nt-card-placeholder">&nbsp;</span>
              </span>
              <span className="nt-card-title nt-card-placeholder">&nbsp;</span>
              <span className="nt-card-message">
                <span className="nt-card-placeholder">&nbsp;</span>
              </span>
            </div>
          ))}
        </div>
      ) : cards.length === 0 ? (
        <p className="nt-chats-empty">{nt("noChats")}</p>
      ) : (
        <div ref={list} className="nt-cards" data-variant={variant}>
          {cards.map((card) => (
            // Its right-click menu: Open, and Open in Terminal (cx-2lm4).
            <ContextMenu
              key={card.sessionId}
              className="nt-card-host"
              items={[
                { id: "open", label: nt("row.open"), onSelect: () => onOpen(card.sessionId) },
                ...(onOpenInTerminal && card.chatKey
                  ? [
                      {
                        id: "terminal",
                        label: t("shell.openInTerminal"),
                        onSelect: () => onOpenInTerminal(card.sessionId),
                      },
                    ]
                  : []),
              ]}
            >
              {/* The chats this chat's agent started, collapsed under it with their count (Leo
                  2026-10-14); a click lists them below it. */}
              {card.children && card.children.length > 0 ? (
                <div className="nt-card-family">
                  {row(card, false)}
                  <button
                    type="button"
                    className="nt-card-children-toggle"
                    aria-expanded={open.has(card.sessionId)}
                    aria-label={nt("card.children", { n: String(card.children.length) })}
                    onClick={() => toggle(card.sessionId)}
                  >
                    {card.children.length}
                  </button>
                  {open.has(card.sessionId) && (
                    <div className="nt-card-children">{card.children.map((child) => row(child, true))}</div>
                  )}
                </div>
              ) : (
                row(card, false)
              )}
            </ContextMenu>
          ))}
        </div>
      )}
    </section>
  );
}

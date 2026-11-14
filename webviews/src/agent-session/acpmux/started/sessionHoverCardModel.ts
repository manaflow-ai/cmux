import { createContext } from "react";
import { type SessionHoverStore } from "./sessionHover";

/// The pointer's rest on a reference before its card shows: shorter than a sidebar row's
/// preview (`HOVER_INTENT.cardDwell`), since a reference in prose is something to read about.
export const SESSION_HOVER_DELAY = 500;

/// Where the cards read sessions from, and how a click opens one. Absent (started session cards
/// off), references draw no card.
export type SessionHover = { store: SessionHoverStore; open(sessionId: string): void };
export const SessionHoverContext = createContext<SessionHover | null>(null);

/// Which side of reference `anchor` its card takes: below, unless more of its text block (the
/// paragraph or list item it sits in) runs under it, where the card would cover the next line.
export function hoverCardSide(anchor: Element): "top" | "bottom" {
  const block = anchor.closest("p, li, blockquote, td, th, h1, h2, h3, h4, h5, h6");
  if (!block) return "bottom";
  return block.getBoundingClientRect().bottom - anchor.getBoundingClientRect().bottom > 2 ? "top" : "bottom";
}

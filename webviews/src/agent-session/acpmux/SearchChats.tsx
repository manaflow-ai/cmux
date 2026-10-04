import React, { useState } from "react";
import { projectLabel, sessionTitle, type AcpmuxSessionEntry } from "./sessionList";
import { useT } from "./i18n";
import { SHORTCUT_ACTIONS, useShortcut, withShortcut } from "./shortcuts";

/** How many chats the palette lists (⌃1 to ⌃9 open them). */
export const SEARCH_CHAT_LIMIT = 9;

/** Newest chats whose title contains `query` (case-insensitive), at most nine. */
export function searchChats(sessions: readonly AcpmuxSessionEntry[], query: string): AcpmuxSessionEntry[] {
  const needle = query.trim().toLowerCase();
  return [...sessions]
    .filter((session) => session.status !== "closed")
    .sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0))
    .filter((session) => !needle || chatTitle(session).toLowerCase().includes(needle))
    .slice(0, SEARCH_CHAT_LIMIT);
}

/** Where the sheet is: hidden, shown, or playing its exit animation (still mounted). */
export type SearchState = "closed" | "open" | "closing";

/** Whether the sheet animates: the open and exit animations run only without Reduce Motion
 * (searchChats.css), so with it no animationend arrives and a close must finish at once. */
export function searchAnimates(): boolean {
  return typeof window !== "undefined" && typeof window.matchMedia === "function"
    ? window.matchMedia("(prefers-reduced-motion: no-preference)").matches
    : false;
}

/** The next sheet state. `toggle` is Cmd-K, `close` is Escape, the scrim or a picked row,
 * `exited` is the end of the exit animation. A toggle during the exit reopens at once; the
 * open animation then starts from the frame on screen. */
export function nextSearchState(
  state: SearchState,
  event: "toggle" | "close" | "exited",
  animates: boolean,
): SearchState {
  const closed: SearchState = animates ? "closing" : "closed";
  switch (event) {
    case "toggle":
      return state === "open" ? closed : "open";
    case "close":
      return state === "open" ? closed : state;
    case "exited":
      return state === "closing" ? "closed" : state;
  }
}

const chatTitle = (session: AcpmuxSessionEntry) => session.displayTitle ?? sessionTitle(session);

type Row = { key: string; label: string; meta?: string; shortcut?: string; run(): void };

/// Cmd-K "Search chats" (reference prototype search.png): the newest chats filtered by title as
/// you type, then quick actions. Arrow keys move the highlight, Enter opens it, Ctrl-1 to
/// Ctrl-9 open a listed chat, Escape or a click outside closes. Query and highlight are view
/// state; opening a chat goes through the pane's chat.select action.
export function SearchChats({
  sessions,
  onSelect,
  onNewChat,
  onClose,
  closing = false,
  onExited,
}: {
  sessions: readonly AcpmuxSessionEntry[];
  onSelect(sessionId: string): void;
  onNewChat(): void;
  onClose(): void;
  /** The exit animation plays: the sheet ignores input and reports its end with `onExited`. */
  closing?: boolean;
  onExited?(): void;
}) {
  const t = useT();
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const chats: Row[] = searchChats(sessions, query).map((session, index) => ({
    key: session.sessionId,
    label: chatTitle(session),
    meta: session.cwd ? projectLabel(session.cwd) : undefined,
    shortcut: `⌃${index + 1}`,
    run: () => onSelect(session.sessionId),
  }));
  const needle = query.trim().toLowerCase();
  // The palette opens and closes on the app's Search chats shortcut, as the user bound it.
  const toggle = useShortcut(SHORTCUT_ACTIONS.searchChats);
  // New chat starts one in this pane; no app shortcut does that, so it shows none.
  const actions: Row[] = [{ key: "new-chat", label: t("search.newChat"), run: onNewChat }].filter(
    (row) => !needle || row.label.toLowerCase().includes(needle),
  );
  const rows = [...chats, ...actions];
  const current = Math.min(active, Math.max(rows.length - 1, 0));
  const onKey = (event: React.KeyboardEvent<HTMLInputElement>) => {
    // IME composition owns Enter, arrows and Escape until it ends.
    if (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      setActive(rows.length ? (current + step + rows.length) % rows.length : 0);
    } else if (event.key === "Enter") {
      event.preventDefault();
      rows[current]?.run();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onClose();
    } else if (event.ctrlKey && /^[1-9]$/.test(event.key)) {
      event.preventDefault();
      chats[Number(event.key) - 1]?.run();
    }
  };
  const row = (item: Row, index: number) => (
    <li key={item.key}>
      <button
        type="button"
        className={`acpmux-search-row${index === current ? " is-active" : ""}`}
        aria-current={index === current || undefined}
        onMouseMove={() => index !== current && setActive(index)}
        onClick={item.run}
      >
        <span className="acpmux-search-label">{item.label}</span>
        {item.meta && <span className="acpmux-search-meta">{item.meta}</span>}
        {item.shortcut && <kbd className="acpmux-search-kbd">{item.shortcut}</kbd>}
      </button>
    </li>
  );
  return (
    <div className={`acpmux-search-layer${closing ? " is-closing" : ""}`} aria-hidden={closing || undefined}>
      <button
        type="button"
        className="acpmux-search-scrim"
        aria-label={t("search.close")}
        tabIndex={-1}
        onClick={onClose}
      />
      {/* A positioned sheet inside the pane, not the browser's top-layer dialog. */}
      <div
        className="acpmux-search"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="dialog"
        aria-modal="true"
        aria-label={t("search.title")}
        onAnimationEnd={(event) => {
          // Only the sheet's own exit ends the close (not its open animation or a child's).
          if (closing && event.target === event.currentTarget) onExited?.();
        }}
      >
        <input
          className="acpmux-search-input"
          // The palette exists to type into: it opens from Cmd-K or the sidebar's search.
          // oxlint-disable-next-line jsx-a11y/no-autofocus
          autoFocus
          type="search"
          spellCheck={false}
          readOnly={closing}
          aria-label={t("search.title")}
          title={withShortcut(t("search.title"), toggle)}
          placeholder={t("search.placeholder")}
          value={query}
          onChange={(event) => {
            setQuery(event.target.value);
            setActive(0);
          }}
          onKeyDown={onKey}
        />
        <div className="acpmux-search-results">
          {chats.length > 0 && <div className="acpmux-search-section">{t("search.chats")}</div>}
          <ul>{chats.map(row)}</ul>
          {actions.length > 0 && <div className="acpmux-search-section">{t("search.quick")}</div>}
          <ul>{actions.map((item, index) => row(item, chats.length + index))}</ul>
          {rows.length === 0 && <div className="acpmux-search-section">{t("search.none")}</div>}
        </div>
      </div>
    </div>
  );
}

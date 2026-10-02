import React, { useState } from "react";
import { projectLabel, sessionTitle, type AcpmuxSessionEntry } from "./sessionList";
import { t } from "./i18n";

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

const chatTitle = (session: AcpmuxSessionEntry) => session.displayTitle ?? sessionTitle(session);

type Row = { key: string; label: string; meta?: string; shortcut?: string; run(): void };

/// Cmd-K "Search chats" (codex-atlas-clone search.png): the newest chats filtered by title as
/// you type, then quick actions. Arrow keys move the highlight, Enter opens it, Ctrl-1 to
/// Ctrl-9 open a listed chat, Escape or a click outside closes. Query and highlight are view
/// state; opening a chat goes through the pane's chat.select action.
export function SearchChats({
  sessions,
  onSelect,
  onNewChat,
  onClose,
}: {
  sessions: readonly AcpmuxSessionEntry[];
  onSelect(sessionId: string): void;
  onNewChat(): void;
  onClose(): void;
}) {
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
  const actions: Row[] = [{ key: "new-chat", label: t("search.newChat"), shortcut: "⌘N", run: onNewChat }].filter(
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
    <div className="acpmux-search-layer">
      <button
        type="button"
        className="acpmux-search-scrim"
        aria-label={t("search.close")}
        tabIndex={-1}
        onClick={onClose}
      />
      {/* A positioned sheet inside the pane, not the browser's top-layer dialog. */}
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
      <div className="acpmux-search" role="dialog" aria-modal="true" aria-label={t("search.title")}>
        <input
          className="acpmux-search-input"
          // The palette exists to type into: it opens from Cmd-K or the sidebar's search.
          // oxlint-disable-next-line jsx-a11y/no-autofocus
          autoFocus
          type="search"
          spellCheck={false}
          aria-label={t("search.title")}
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

// ⌘K "Search chats" (search.png): acpmux sessions filtered by title as you type, then quick
// actions. Arrow keys move the highlight, Enter opens, Escape or the scrim closes. The query
// and highlight are view state.
import { useState, type ReactNode } from "react";
import { IconCompose } from "../shell/icons";
import { projectLabel, type AcpmuxSessionEntry } from "../data/acpmux";
import "./search-palette.css";

const MAX_CHATS = 9;

type Row = { key: string; label: string; meta?: string; shortcut?: string; icon?: ReactNode; run: () => void };

export function SearchPalette({
  sessions,
  onSelect,
  onNewChat,
  onClose,
}: {
  sessions: AcpmuxSessionEntry[];
  onSelect: (sessionId: string) => void;
  onNewChat: () => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const q = query.trim().toLowerCase();
  const title = (session: AcpmuxSessionEntry) => session.displayTitle ?? session.title ?? session.sessionId.slice(0, 8);
  const chats: Row[] = [...sessions]
    .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))
    .filter((session) => !q || title(session).toLowerCase().includes(q))
    .slice(0, MAX_CHATS)
    .map((session, index) => ({
      key: session.sessionId,
      label: title(session),
      meta: session.cwd ? projectLabel(session.cwd) : undefined,
      shortcut: `⌃${index + 1}`,
      run: () => onSelect(session.sessionId),
    }));
  const actions: Row[] = [
    { key: "new-chat", label: "New chat", shortcut: "⌘N", icon: <IconCompose size={16} />, run: onNewChat },
  ].filter((row) => !q || row.label.toLowerCase().includes(q));
  const rows = [...chats, ...actions];
  const current = Math.min(active, rows.length - 1);
  const row = (r: Row, index: number) => (
    <button
      type="button"
      key={r.key}
      aria-current={index === current || undefined}
      className={`cm-row${index === current ? " is-active" : ""}${r.icon ? " has-icon" : ""}`}
      onClick={r.run}
    >
      {r.icon && <span className="cm-row__icon">{r.icon}</span>}
      <span className="cm-row__label">{r.label}</span>
      {r.meta && <span className="cm-row__meta">{r.meta}</span>}
      {r.shortcut && <span className="cm-row__kbd">{r.shortcut}</span>}
    </button>
  );
  return (
    <>
      <button type="button" className="cm-scrim" aria-label="Close search" tabIndex={-1} onClick={onClose} />
      <div className="cm-menu" aria-label="Search chats">
        <div className="cm-input">
          <input
            className="cm-input__field"
            // The palette exists to type into; it opens from a keypress or a click.
            // oxlint-disable-next-line jsx-a11y/no-autofocus
            autoFocus
            aria-label="Search chats"
            placeholder="Search chats"
            value={query}
            onChange={(event) => {
              setQuery(event.currentTarget.value);
              setActive(0);
            }}
            onKeyDown={(event) => {
              if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                event.preventDefault();
                const delta = event.key === "ArrowDown" ? 1 : -1;
                setActive((index) => (rows.length ? (index + delta + rows.length) % rows.length : 0));
              } else if (event.key === "Enter") rows[current]?.run();
              else if (event.key === "Escape") onClose();
            }}
          />
        </div>
        <div>
          {chats.length > 0 && <div className="cm-section">Chats</div>}
          {chats.map(row)}
          {actions.length > 0 && <div className="cm-section cm-section--quick">Quick actions</div>}
          {actions.map((r, index) => row(r, chats.length + index))}
          {rows.length === 0 && <div className="cm-section">No results</div>}
        </div>
      </div>
    </>
  );
}

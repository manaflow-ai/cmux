import React, { useEffect, useId, useMemo, useRef, useState } from "react";
import { filterSessions, projectLabel, sessionTitle, type AcpmuxSessionEntry } from "./sessionList";

/// Palette copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const SEARCH_CHATS_LABELS = {
  search: "Search chats",
  none: "No matching chats",
  empty: "No chats yet",
};

/// The palette lists at most this many chats; typing narrows the rest.
export const SEARCH_CHATS_LIMIT = 50;
/// Ctrl+1 through Ctrl+9 open the first nine rows.
const NUMBERED_ROWS = 9;

/// Cmd+K toggles the palette while the pane has focus. Nothing else in the pane or the app
/// binds plain Cmd+K there: the simulator's Cmd+K applies only to a focused simulator, and
/// terminal clear is Cmd+Shift+K. A key that belongs to an input method's composition is not it.
export function isSearchChatsKey(
  event: Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey" | "isComposing" | "keyCode">,
) {
  if (event.isComposing || event.keyCode === 229) return false;
  return event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "k";
}

/// The chats a query lists: every word must match (as the sidebar filter), newest first.
export function searchChats(sessions: AcpmuxSessionEntry[], query: string): AcpmuxSessionEntry[] {
  return [...filterSessions(sessions, query)]
    .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))
    .slice(0, SEARCH_CHATS_LIMIT);
}

/// Codex's "Search chats" palette (codex-atlas-clone reference command-menu-chats): a field
/// over the transcript listing chats, newest first, narrowed as the user types. Arrows move
/// the highlight, Enter or Ctrl+1..9 opens a chat, and Escape, Tab or a click outside close it.
export function SearchChats({
  sessions,
  selectedId,
  onPick,
  onClose,
}: {
  sessions: AcpmuxSessionEntry[];
  selectedId?: string;
  onPick(sessionId: string): void;
  onClose(): void;
}) {
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const field = useRef<HTMLInputElement>(null);
  const root = useRef<HTMLDialogElement>(null);
  const listId = useId();
  const results = useMemo(() => searchChats(sessions, query), [sessions, query]);
  const selected = Math.min(active, Math.max(results.length - 1, 0));

  useEffect(() => {
    // Focus returns where it was (the composer, a sidebar row) when the palette closes.
    const before = document.activeElement as HTMLElement | null;
    field.current?.focus();
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) onCloseRef.current();
    };
    document.addEventListener("pointerdown", away);
    return () => {
      document.removeEventListener("pointerdown", away);
      if (before?.isConnected) before.focus();
    };
  }, []);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  const pick = (session: AcpmuxSessionEntry | undefined) => {
    if (session) onPick(session.sessionId);
  };

  const keyDown = (event: React.KeyboardEvent) => {
    // Keys that commit or cancel an input method's text belong to it, not the palette.
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    const numbered = event.ctrlKey && !event.metaKey && !event.altKey && /^[1-9]$/.test(event.key);
    if (numbered) {
      event.preventDefault();
      const index = Number(event.key) - 1;
      if (index < NUMBERED_ROWS) pick(results[index]);
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onClose();
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (results.length > 0)
        setActive((selected + (event.key === "ArrowDown" ? 1 : -1) + results.length) % results.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(results[selected]);
    } else if (event.key === "Tab") {
      onClose();
    }
  };

  const note =
    results.length > 0 ? undefined : sessions.length === 0 ? SEARCH_CHATS_LABELS.empty : SEARCH_CHATS_LABELS.none;

  return (
    <dialog ref={root} open className="acpmux-search-chats" aria-label={SEARCH_CHATS_LABELS.search}>
      <input
        ref={field}
        type="text"
        // A combobox that owns the result list: the role carries aria-expanded and aria-controls.
        // oxlint-disable-next-line jsx-a11y/no-redundant-roles
        role="combobox"
        aria-label={SEARCH_CHATS_LABELS.search}
        aria-expanded={results.length > 0}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={results.length > 0 ? `${listId}-${selected}` : undefined}
        placeholder={SEARCH_CHATS_LABELS.search}
        value={query}
        spellCheck={false}
        autoComplete="off"
        onChange={(event) => {
          setQuery(event.target.value);
          setActive(0);
        }}
        onKeyDown={keyDown}
      />
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
      <div id={listId} role="listbox" aria-label={SEARCH_CHATS_LABELS.search}>
        {results.map((session, index) => {
          const project = projectLabel(session.cwd);
          return (
            <div
              key={session.sessionId}
              id={`${listId}-${index}`}
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="option"
              tabIndex={-1}
              aria-selected={index === selected}
              aria-current={session.sessionId === selectedId ? "page" : undefined}
              className={`acpmux-chat-result${index === selected ? " acpmux-menu-active" : ""}`}
              onPointerMove={() => setActive(index)}
              onMouseDown={(event) => {
                event.preventDefault();
                pick(session);
              }}
            >
              <span className="acpmux-chat-title">{session.displayTitle || sessionTitle(session)}</span>
              {project && <span className="acpmux-chat-project">{project}</span>}
              {/* Every row keeps the key column, so project names line up past the ninth. */}
              <kbd className="acpmux-chat-key" aria-hidden="true">
                {index < NUMBERED_ROWS ? `⌃${index + 1}` : ""}
              </kbd>
            </div>
          );
        })}
      </div>
      {note && <output className="acpmux-chat-note">{note}</output>}
    </dialog>
  );
}

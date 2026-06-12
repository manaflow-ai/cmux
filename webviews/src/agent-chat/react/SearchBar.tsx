// Search bar for the /agent-chat surface. Pure view over SearchUIState: the
// parent owns the reducer and the derived match list; this component only
// renders and forwards events. Enter/Shift+Enter step through matches, Escape
// closes (which also clears the query upstream).

import { useEffect } from "react";
import type { KeyboardEvent as ReactKeyboardEvent } from "react";
import { agentChatLabels, matchCounterLabel } from "../labels";

/**
 * Document-level Cmd+F/Ctrl+F → open the search bar. An effect is unavoidable
 * for a document listener; narrow contract per the repo React rules: attaches
 * exactly one keydown listener for the component's lifetime and calls the
 * (stable) `onOpen` on the find chord, nothing else. The browser/webview find
 * UI is suppressed only for this chord.
 */
export function useSearchHotkey(onOpen: () => void) {
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && event.key === "f") {
        event.preventDefault();
        onOpen();
      }
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [onOpen]);
}

// Focus exactly once per mounted input node (the input is re-keyed per open
// request, so each open mounts a fresh node). Module-level and WeakSet-guarded:
// the ref identity is stable across renders, so ordinary search-bar updates
// (typing, next/prev, filter toggle) never steal focus back to the field.
const focusedOnMount = new WeakSet<HTMLInputElement>();
function focusOnFirstMount(node: HTMLInputElement | null) {
  if (node && !focusedOnMount.has(node)) {
    focusedOnMount.add(node);
    node.focus();
  }
}

export function SearchBar({
  openCount,
  query,
  filterMode,
  cursor,
  matchCount,
  onQueryChange,
  onStep,
  onToggleFilter,
  onClose,
}: {
  openCount: number;
  query: string;
  filterMode: boolean;
  cursor: number;
  matchCount: number;
  onQueryChange: (query: string) => void;
  onStep: (direction: 1 | -1) => void;
  onToggleFilter: () => void;
  onClose: () => void;
}) {
  const handleKeyDown = (event: ReactKeyboardEvent<HTMLInputElement>) => {
    // During IME composition Enter confirms the candidate (and Escape cancels
    // it); intercepting those keys would break Japanese/Chinese/Korean input.
    if (event.nativeEvent.isComposing || event.keyCode === 229) {
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      onStep(event.shiftKey ? -1 : 1);
    } else if (event.key === "Escape") {
      event.preventDefault();
      onClose();
    }
  };
  const hasQuery = query.trim() !== "";
  return (
    <search className="agent-chat-search-bar">
      <input
        // Re-keying on every open request re-mounts the input, and the
        // first-mount ref focuses the fresh node (repeat Cmd+F refocuses the
        // field without an effect, later renders never steal focus).
        key={`search-input-${openCount}`}
        ref={focusOnFirstMount}
        className="agent-chat-search-input"
        type="text"
        value={query}
        placeholder={agentChatLabels.searchPlaceholder}
        aria-label={agentChatLabels.searchPlaceholder}
        spellCheck={false}
        onChange={(event) => onQueryChange(event.target.value)}
        onKeyDown={handleKeyDown}
      />
      <span className="agent-chat-search-counter" data-empty={!hasQuery || matchCount > 0 ? "false" : "true"}>
        {!hasQuery
          ? ""
          : matchCount === 0
            ? agentChatLabels.searchNoMatches
            : matchCounterLabel(cursor + 1, matchCount)}
      </span>
      <button
        type="button"
        className="agent-chat-search-button"
        title={agentChatLabels.searchPreviousMatch}
        aria-label={agentChatLabels.searchPreviousMatch}
        disabled={matchCount === 0}
        onClick={() => onStep(-1)}
      >
        ↑
      </button>
      <button
        type="button"
        className="agent-chat-search-button"
        title={agentChatLabels.searchNextMatch}
        aria-label={agentChatLabels.searchNextMatch}
        disabled={matchCount === 0}
        onClick={() => onStep(1)}
      >
        ↓
      </button>
      <button
        type="button"
        className="agent-chat-search-button is-toggle"
        title={agentChatLabels.searchFilterToggle}
        aria-label={agentChatLabels.searchFilterToggle}
        aria-pressed={filterMode}
        data-active={filterMode ? "true" : "false"}
        onClick={onToggleFilter}
      >
        ☰
      </button>
      <button
        type="button"
        className="agent-chat-search-button"
        title={agentChatLabels.searchClose}
        aria-label={agentChatLabels.searchClose}
        onClick={onClose}
      >
        ✕
      </button>
    </search>
  );
}

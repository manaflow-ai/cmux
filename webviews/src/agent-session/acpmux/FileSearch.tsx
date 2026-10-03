import React, { useEffect, useId, useRef, useState } from "react";
import {
  failureReason,
  matchRuns,
  OUTSIDE_REPOSITORY,
  readFileSearch,
  type FileMatch,
  type FileSearchSource,
  type Run,
} from "./fileSearchModel";
import { t } from "./i18n";

/// How long typing settles before the palette asks again.
const SEARCH_DEBOUNCE_MS = 80;

type State =
  | { kind: "idle" }
  | { kind: "searching"; results: FileMatch[] }
  | { kind: "done"; results: FileMatch[]; truncated: boolean }
  | { kind: "failed"; outside?: boolean };

/// The "Search files" palette:
/// a field over the transcript that lists the session's files matching what is typed, best
/// first, with the matched characters bold. Arrows move the highlight, Enter picks and Escape
/// closes; picking hands the path back, and the composer mentions it.
export function FileSearch({
  search,
  onPick,
  onClose,
  debounceMs = SEARCH_DEBOUNCE_MS,
}: {
  search: FileSearchSource;
  onPick(path: string): void;
  onClose(): void;
  /// Tests shorten it.
  debounceMs?: number;
}) {
  const [query, setQuery] = useState("");
  const [state, setState] = useState<State>({ kind: "idle" });
  const [active, setActive] = useState(0);
  const field = useRef<HTMLInputElement>(null);
  const root = useRef<HTMLDialogElement>(null);
  const listId = useId();
  // Only the newest request's answer lands; an older one that resolves late is dropped.
  const generation = useRef(0);

  useEffect(() => {
    field.current?.focus();
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) onCloseRef.current();
    };
    document.addEventListener("pointerdown", away);
    const requests = generation;
    return () => {
      document.removeEventListener("pointerdown", away);
      // A request still in flight answers into a closed palette; its answer is dropped.
      requests.current++;
    };
  }, []);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  useEffect(() => {
    const ask = ++generation.current;
    const text = query.trim();
    if (!text) {
      setState({ kind: "idle" });
      return;
    }
    setState((current) => ({
      kind: "searching",
      results: current.kind === "done" || current.kind === "searching" ? current.results : [],
    }));
    const timer = setTimeout(() => {
      search(text).then(
        (reply) => {
          if (ask !== generation.current) return;
          const result = readFileSearch(reply);
          setState(
            result ? { kind: "done", results: result.results, truncated: !!result.truncated } : { kind: "failed" },
          );
          setActive(0);
        },
        (error: unknown) => {
          if (ask === generation.current)
            setState({ kind: "failed", outside: failureReason(error) === OUTSIDE_REPOSITORY });
        },
      );
    }, debounceMs);
    return () => clearTimeout(timer);
  }, [query, search, debounceMs]);

  const results = state.kind === "done" || state.kind === "searching" ? state.results : [];
  const selected = Math.min(active, Math.max(results.length - 1, 0));
  const pick = (match: FileMatch | undefined) => {
    if (match) onPick(match.path);
  };

  const keyDown = (event: React.KeyboardEvent) => {
    // Keys that commit or cancel an input method's text belong to it, not the palette.
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onClose();
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (results.length > 0)
        setActive((selected + (event.key === "ArrowDown" ? 1 : -1) + results.length) % results.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      // While a newer query is out, the highlighted row on screen is still what Enter picks.
      pick(results[selected]);
    } else if (event.key === "Tab") {
      // Closing hands focus back to the prompt; Tab's own move would carry it past.
      event.preventDefault();
      onClose();
    }
  };

  const note =
    state.kind === "idle"
      ? t("files.hint")
      : state.kind === "failed"
        ? state.outside
          ? t("files.outside")
          : t("files.failed")
        : state.kind === "searching" && results.length === 0
          ? t("files.searching")
          : state.kind === "done" && results.length === 0
            ? t("files.none")
            : undefined;

  return (
    <dialog ref={root} open className="acpmux-file-search" aria-label={t("files.search")}>
      <input
        ref={field}
        type="text"
        // A combobox that owns the result list: the role carries aria-expanded and aria-controls.
        // oxlint-disable-next-line jsx-a11y/no-redundant-roles
        role="combobox"
        aria-label={t("files.search")}
        aria-expanded={results.length > 0}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={results.length > 0 ? `${listId}-${selected}` : undefined}
        placeholder={t("files.search")}
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
      <div id={listId} role="listbox" aria-label={t("files.search")} aria-busy={state.kind === "searching"}>
        {results.map((match, index) => {
          const { dir, name } = matchRuns(match.path, match.matches);
          return (
            <div
              key={match.path}
              id={`${listId}-${index}`}
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="option"
              tabIndex={-1}
              aria-selected={index === selected}
              className={`acpmux-file-result${index === selected ? " acpmux-menu-active" : ""}`}
              title={match.path}
              onPointerMove={() => setActive(index)}
              onMouseDown={(event) => {
                event.preventDefault();
                pick(match);
              }}
            >
              <span className="acpmux-file-name">{runs(name)}</span>
              {dir.length > 0 && <span className="acpmux-file-dir">{runs(dir)}</span>}
            </div>
          );
        })}
      </div>
      {note && <output className="acpmux-file-note">{note}</output>}
      {state.kind === "done" && state.truncated && results.length > 0 && (
        <output className="acpmux-file-note">{t("files.more", { count: results.length })}</output>
      )}
    </dialog>
  );
}

function runs(parts: Run[]) {
  return parts.map((part, index) => (part.matched ? <b key={index}>{part.text}</b> : part.text));
}

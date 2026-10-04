// The in-page folder and file picker. The dev server answers `cmux.diff.chooseFolder` and
// `cmux.markdown.chooseFile` with it; it is also the reference for the app's palette picker, which
// keeps the same interaction (pickerModel.ts has the rules):
//   - one folder level at a time, recent folders first, git repositories marked;
//   - typing filters the level (fuzzy); a query starting with "." also lists hidden entries;
//   - Tab or Right enters the highlighted folder; Left, or Backspace on an empty query, goes up;
//   - Enter chooses (a folder in folder mode; a file, or enters a folder, in file mode);
//   - `~` and `/` jump home and to the root, `name/` enters that folder; the breadcrumb navigates.
// Listings come from `list` (`cmux.picker.list`), which may refuse a folder outside its roots.
import { useId, useRef, useState, type KeyboardEvent } from "react";
import type { Strings } from "../pages/shared/i18n";
import { EmptyIcon } from "./icons";
import { isPickerListing, type PickerListing, type PickerMode } from "./ops";
import {
  PICKER_ROW_LIMIT,
  breadcrumb,
  pickerKeyAction,
  pickerRows,
  queryJump,
  recentPathSet,
  type PickerRow,
} from "./pickerModel";
import { E } from "./strings";

export type PickerList = (path: string | null, options: { mode: PickerMode; hidden: boolean }) => Promise<unknown>;

export interface PathPickerProps {
  mode: PickerMode;
  list: PickerList;
  strings: Strings;
  /** Recent paths (repositories or files), newest first: sorted first and marked. */
  recents?: readonly string[];
  /** The folder to open first; null lets the host pick (home). */
  start?: string | null;
  onChoose(path: string): void;
  onCancel(): void;
  /** The title and empty-folder text, when the page has its own (the code editor's any-file mode). */
  labels?: { title?: string; empty?: string };
}

type Load = { phase: "loading" } | { phase: "failed" } | { phase: "ready" };

export function PathPicker({
  mode,
  list,
  strings,
  recents = [],
  start = null,
  onChoose,
  onCancel,
  labels,
}: PathPickerProps) {
  const { t } = strings;
  const [listing, setListing] = useState<PickerListing | null>(null);
  const [load, setLoad] = useState<Load>({ phase: "loading" });
  const [query, setQuery] = useState("");
  const [highlight, setHighlight] = useState(0);
  const request = useRef(0);
  const started = useRef(false);
  const listId = useId();
  const recentSet = recentPathSet(recents, mode);

  const navigate = async (path: string | null, options: { focus?: string; hidden?: boolean } = {}) => {
    const id = ++request.current;
    setLoad({ phase: "loading" });
    let value: unknown;
    try {
      value = await list(path, { mode, hidden: options.hidden ?? false });
    } catch {
      if (id === request.current) setLoad({ phase: "failed" });
      return;
    }
    if (id !== request.current) return;
    if (!isPickerListing(value)) return setLoad({ phase: "failed" });
    setListing(value);
    setLoad({ phase: "ready" });
    const rows = pickerRows(value.entries, options.hidden ? "." : "", mode, recentSet);
    const index = options.focus ? rows.findIndex((row) => row.path === options.focus) : -1;
    setHighlight(Math.max(index, 0));
  };

  // A callback ref: the first listing loads when the picker mounts, and the field takes focus.
  const mountRef = (element: HTMLDivElement | null) => {
    if (!element || started.current) return;
    started.current = true;
    void navigate(start);
  };

  const all = listing ? pickerRows(listing.entries, query.startsWith(".") ? "." : "", mode, recentSet) : [];
  const rows = listing ? pickerRows(listing.entries, query, mode, recentSet) : [];
  const shown = rows.slice(0, PICKER_ROW_LIMIT);
  const current: PickerRow | undefined = shown[Math.min(highlight, shown.length - 1)];

  const go = (path: string | null, focus?: string) => {
    setQuery("");
    void navigate(path, { focus });
  };
  const goUp = () => {
    if (!listing?.parent) return;
    go(listing.parent, listing.path);
  };
  const enter = (row: PickerRow | undefined) => {
    if (row?.kind === "dir") go(row.path);
  };
  const choose = (row: PickerRow | undefined) => {
    if (!row) {
      // Folder mode with nothing to highlight (an empty folder, no subfolders) chooses the folder.
      if (mode === "folder" && query === "" && listing && load.phase === "ready") onChoose(listing.path);
      return;
    }
    if (mode !== "folder" && row.kind === "dir") return enter(row);
    onChoose(row.path);
  };

  const setQueryValue = (value: string) => {
    const jump = queryJump(value, all, listing?.home ?? null);
    if (jump) return go(jump.path);
    const hiddenBefore = query.startsWith(".");
    setQuery(value);
    setHighlight(0);
    if (value.startsWith(".") !== hiddenBefore && listing) {
      void navigate(listing.path, { hidden: value.startsWith(".") });
    }
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    const input = event.currentTarget;
    const action = pickerKeyAction(event, {
      query,
      caretStart: input.selectionStart ?? query.length,
      caretEnd: input.selectionEnd ?? query.length,
    });
    if (!action) return;
    event.preventDefault();
    event.stopPropagation();
    switch (action.kind) {
      case "move":
        if (shown.length) setHighlight(Math.max(0, Math.min(shown.length - 1, highlight + action.delta)));
        return;
      case "edge":
        setHighlight(action.to === "first" ? 0 : Math.max(0, shown.length - 1));
        return;
      case "enter":
        return enter(current);
      case "up":
        return goUp();
      case "choose":
        return choose(current);
      case "clear":
        return setQueryValue("");
      case "cancel":
        return onCancel();
    }
  };

  const crumbs = listing ? breadcrumb(listing.path, listing.home) : [];
  const emptyText =
    load.phase === "failed"
      ? t(E.pickerFailed)
      : load.phase === "loading" && !listing
        ? t(E.pickerLoading)
        : query !== ""
          ? t(E.pickerNoMatches)
          : (labels?.empty ?? t(mode === "folder" ? E.pickerEmptyFolder : E.pickerEmptyFile));

  return (
    <div
      ref={mountRef}
      className="ve-picker"
      data-mode={mode}
      data-phase={load.phase}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="dialog"
      aria-label={labels?.title ?? t(mode === "folder" ? E.pickerFolderTitle : E.pickerFileTitle)}
    >
      <div className="ve-picker-head">
        <span className="ve-picker-title">
          {labels?.title ?? t(mode === "folder" ? E.pickerFolderTitle : E.pickerFileTitle)}
        </span>
        <nav className="ve-crumbs" aria-label={t(E.pickerLocation)}>
          {crumbs.map((crumb, index) => (
            <span key={crumb.path} className="ve-crumb-wrap">
              {index > 0 && crumbs[index - 1].label !== "/" ? <span className="ve-crumb-sep">/</span> : null}
              <button
                type="button"
                className="ve-crumb"
                tabIndex={-1}
                aria-current={index === crumbs.length - 1 ? "location" : undefined}
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => go(crumb.path, crumbs[index + 1]?.path)}
              >
                {crumb.label}
              </button>
            </span>
          ))}
        </nav>
      </div>
      <input
        ref={focusOnMount}
        className="ve-picker-field"
        type="text"
        spellCheck={false}
        autoComplete="off"
        autoCapitalize="off"
        aria-controls={listId}
        aria-activedescendant={current ? `${listId}-${shown.indexOf(current)}` : undefined}
        aria-label={t(E.pickerPlaceholder)}
        placeholder={t(E.pickerPlaceholder)}
        value={query}
        onChange={(event) => setQueryValue(event.target.value)}
        onKeyDown={onKeyDown}
      />
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
      <div className="ve-picker-list" id={listId} role="listbox" aria-label={listing?.path ?? ""}>
        {shown.length === 0 ? (
          <div className="ve-picker-empty" role="presentation">
            {emptyText}
          </div>
        ) : (
          shown.map((row, index) => (
            <div
              key={row.path}
              id={`${listId}-${index}`}
              ref={index === highlight ? scrollIntoViewRef : undefined}
              className="ve-picker-row"
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="option"
              tabIndex={-1}
              aria-selected={index === highlight}
              data-kind={row.kind}
              data-git={row.git ? "true" : undefined}
              data-recent={row.recent ? "true" : undefined}
              title={row.path}
              onMouseDown={(event) => {
                event.preventDefault();
                setHighlight(index);
              }}
              onMouseMove={() => index !== highlight && setHighlight(index)}
              onDoubleClick={() => (row.kind === "dir" ? enter(row) : choose(row))}
            >
              <EmptyIcon
                name={row.kind === "file" ? "file" : row.git ? "repo" : "folder"}
                title={row.git ? t(E.pickerGit) : undefined}
              />
              <span className="ve-picker-name">{row.name}</span>
              {row.recent ? (
                <span className="ve-picker-recent" title={t(E.pickerRecent)}>
                  <EmptyIcon name="clock" />
                </span>
              ) : null}
              {row.kind === "dir" ? (
                <span className="ve-picker-chevron">
                  <EmptyIcon name="chevron" />
                </span>
              ) : null}
            </div>
          ))
        )}
        {rows.length > shown.length ? (
          <div className="ve-picker-more" role="presentation">
            {strings.format(E.pickerMore, String(rows.length - shown.length))}
          </div>
        ) : null}
      </div>
      <div className="ve-picker-foot">
        <span className="ve-picker-hints" aria-hidden="true">
          <span className="ve-hint">
            <kbd>Tab</kbd>
            {t(E.pickerHintOpen)}
          </span>
          <span className="ve-hint">
            <kbd>←</kbd>
            {t(E.pickerHintUp)}
          </span>
          <span className="ve-hint">
            <kbd>↩</kbd>
            {t(E.pickerHintChoose)}
          </span>
        </span>
        <span className="ve-picker-actions">
          <button type="button" className="ve-button" onClick={onCancel}>
            {t(E.pickerCancel)}
          </button>
          {mode === "folder" ? (
            <button
              type="button"
              className="ve-button ve-button-primary"
              disabled={!listing || load.phase !== "ready"}
              onClick={() => listing && onChoose(listing.path)}
            >
              {t(E.pickerChooseThis)}
            </button>
          ) : null}
        </span>
      </div>
    </div>
  );
}

function focusOnMount(element: HTMLInputElement | null): void {
  element?.focus({ preventScroll: true });
}

function scrollIntoViewRef(element: HTMLElement | null): void {
  if (element && typeof element.scrollIntoView === "function") element.scrollIntoView({ block: "nearest" });
}

/** The picker as a palette-like sheet over the page: a click outside cancels. */
export function PathPickerDialog(props: PathPickerProps) {
  return (
    <div
      className="ve-sheet"
      role="presentation"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) props.onCancel();
      }}
    >
      <PathPicker {...props} />
    </div>
  );
}

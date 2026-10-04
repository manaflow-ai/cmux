// The in-page folder and file picker. The dev server answers `cmux.diff.chooseFolder` and
// `cmux.markdown.chooseFile` with it; it is also the reference for the app's palette picker, which
// keeps the same interaction (pickerModel.ts has the rules, ui/drillKeys.ts the keys):
//   - one folder level at a time, recent folders first, git repositories marked;
//   - a Locations section above the level while the query is empty: home, the computer's root,
//     recent folders;
//   - typing filters the level (fuzzy); a query starting with "." also lists hidden entries;
//   - path mode: a query starting with "/" or "~/" is a path; the picker lists its folder and the
//     last part filters it ("~/fun/cm");
//   - Tab or the inline-end arrow enters the highlighted folder; Cmd-Up, the inline-start arrow, or
//     Backspace on an empty query goes up;
//   - Enter chooses (a folder in folder mode; a file, or enters a folder, in file mode);
//   - `name/` enters that folder; the breadcrumb navigates.
// Listings come from `list` (`cmux.picker.list`), which may refuse a folder outside its roots.
// The widget (roles, keys, highlight, announcements) is ui/DrillList; this file is the model glue.
import { useRef, useState } from "react";
import type { Strings } from "../pages/shared/i18n";
import { Breadcrumbs } from "../ui/Breadcrumbs";
import { Dialog } from "../ui/Dialog";
import { DrillList, type DrillSection } from "../ui/DrillList";
import { EmptyIcon } from "./icons";
import { isPickerListing, tildePath, type PickerListing, type PickerMode } from "./ops";
import {
  PICKER_ROW_LIMIT,
  breadcrumb,
  folderQuery,
  parentPath,
  pathQuery,
  pickerLocations,
  pickerRows,
  queryJump,
  recentPathSet,
  type PickerLocation,
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
type Row = PickerRow | PickerLocation;

const isLocation = (row: Row): row is PickerLocation => "location" in row;
const rowKey = (row: Row) => `${isLocation(row) ? "location" : "row"}:${row.path}`;

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
  // The highlighted row by key (section and path), so a new listing or the Locations above it keep
  // it in place.
  const [highlightKey, setHighlightKey] = useState<string | null>(null);
  const request = useRef(0);
  const started = useRef(false);
  const recentSet = recentPathSet(recents, mode);
  const home = listing?.home ?? null;

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
    const focus = options.focus ? rows.find((row) => row.path === options.focus) : undefined;
    const row = focus ?? rows[0];
    setHighlightKey(row ? rowKey(row) : null);
  };

  // A callback ref: the first listing loads when the picker mounts.
  const mountRef = (element: HTMLElement | null) => {
    if (!element || started.current) return;
    started.current = true;
    void navigate(start);
  };

  // Path mode lists the query's folder; the text after its last "/" filters it.
  const path = pathQuery(query, home);
  const filter = path ? path.rest : query;
  const all = listing ? pickerRows(listing.entries, filter.startsWith(".") ? "." : "", mode, recentSet) : [];
  const rows = listing ? pickerRows(listing.entries, filter, mode, recentSet) : [];
  const shown = rows.slice(0, PICKER_ROW_LIMIT);
  const locations =
    query === "" && listing
      ? pickerLocations({
          home,
          current: listing.path,
          recents,
          mode,
          labels: { home: t(E.pickerHome), computer: t(E.pickerComputer) },
        })
      : [];
  const sections: DrillSection<Row>[] = [
    { id: "locations", label: t(E.pickerLocations), items: locations },
    { id: "level", items: shown },
  ];
  const flat: Row[] = [...locations, ...shown];
  const levelStart = locations.length;
  const found = flat.findIndex((row) => rowKey(row) === highlightKey);
  // Default: the level's first row; none in an empty level (Enter then chooses the folder).
  const highlight = found >= 0 ? found : shown.length ? levelStart : -1;

  const go = (target: string | null, focus?: string) => {
    setQuery("");
    void navigate(target, { focus });
  };
  /** In path mode the field follows the folder; otherwise the query clears. */
  const show = (target: string, focus?: string) => {
    if (path) {
      setQuery(folderQuery(target, home));
      void navigate(target, { focus });
    } else go(target, focus);
  };
  const goUp = () => {
    const parent = listing?.parent ?? (listing ? parentPath(listing.path) : null);
    if (!listing || !parent) return;
    show(parent, listing.path);
  };
  const enter = (row: Row | undefined) => {
    if (row?.kind === "dir") show(row.path);
  };
  const choose = (row: Row | undefined) => {
    if (!row) {
      // Folder mode with nothing to highlight (an empty folder, no subfolders) chooses the folder.
      if (mode === "folder" && (query === "" || (path && path.rest === "")) && listing && load.phase === "ready") {
        onChoose(listing.path);
      }
      return;
    }
    if (isLocation(row) || (mode !== "folder" && row.kind === "dir")) return enter(row);
    onChoose(row.path);
  };

  const setQueryValue = (value: string) => {
    const jump = queryJump(value, all);
    if (jump) return go(jump.path);
    const before = pathQuery(query, home);
    const next = pathQuery(value, home);
    const hiddenBefore = (before ? before.rest : query).startsWith(".");
    const hidden = (next ? next.rest : value).startsWith(".");
    setQuery(value);
    setHighlightKey(null);
    // Leaving path mode keeps the folder it showed.
    if (next && next.dir !== listing?.path) {
      void navigate(next.dir, { hidden });
    } else if (hidden !== hiddenBefore && listing) {
      void navigate(listing.path, { hidden });
    }
  };

  const crumbs = listing ? breadcrumb(listing.path, listing.home) : [];
  const emptyText =
    load.phase === "failed"
      ? t(E.pickerFailed)
      : load.phase === "loading" && !listing
        ? t(E.pickerLoading)
        : filter !== ""
          ? t(E.pickerNoMatches)
          : (labels?.empty ?? t(mode === "folder" ? E.pickerEmptyFolder : E.pickerEmptyFile));
  const title = labels?.title ?? t(mode === "folder" ? E.pickerFolderTitle : E.pickerFileTitle);
  const status =
    load.phase === "failed"
      ? t(E.pickerFailed)
      : load.phase === "loading"
        ? t(E.pickerLoading)
        : listing
          ? strings.format(E.pickerStatus, tildePath(listing.path, listing.home), String(rows.length))
          : "";

  return (
    <section ref={mountRef} className="ve-picker" data-mode={mode} data-phase={load.phase} aria-label={title}>
      <div className="ve-picker-head">
        <span className="ve-picker-title">{title}</span>
        <Breadcrumbs
          className="ve-crumbs"
          crumbClassName="ve-crumb"
          label={t(E.pickerLocation)}
          crumbs={crumbs}
          separator={(index) => (crumbs[index - 1].label !== "/" ? <span className="ve-crumb-sep">/</span> : null)}
          onNavigate={(crumb, index) => show(crumb.path, crumbs[index + 1]?.path)}
        />
      </div>
      <DrillList<Row>
        sections={sections}
        getKey={rowKey}
        highlight={highlight}
        onHighlight={(index) => setHighlightKey(flat[index] ? rowKey(flat[index]) : null)}
        query={query}
        onQueryChange={setQueryValue}
        onEnter={enter}
        onUp={goUp}
        onChoose={choose}
        onCancel={onCancel}
        onActivate={(row) => (row.kind === "dir" ? enter(row) : choose(row))}
        label={t(E.pickerPlaceholder)}
        placeholder={t(E.pickerPlaceholder)}
        listLabel={listing?.path ?? t(E.pickerLoading)}
        hint={t(E.pickerHintPath)}
        status={status}
        empty={emptyText}
        fieldClassName="ve-picker-field"
        listClassName="ve-picker-list"
        rowClassName="ve-picker-row"
        emptyClassName="ve-picker-empty"
        sectionClassName="ve-picker-section"
        hintClassName="ve-picker-hint"
        itemAttributes={(row) => ({
          title: row.path,
          "data-kind": row.kind,
          "data-location": isLocation(row) ? "true" : undefined,
          "data-git": !isLocation(row) && row.git ? "true" : undefined,
          "data-recent": !isLocation(row) && row.recent ? "true" : undefined,
        })}
        renderItem={(row) => (
          <>
            <EmptyIcon
              name={
                isLocation(row)
                  ? row.path === home
                    ? "home"
                    : "folder"
                  : row.kind === "file"
                    ? "file"
                    : row.git
                      ? "repo"
                      : "folder"
              }
              title={!isLocation(row) && row.git ? t(E.pickerGit) : undefined}
            />
            <span className={isLocation(row) ? "ve-picker-location" : "ve-picker-name"}>{row.name}</span>
            {!isLocation(row) && row.recent ? (
              <span className="ve-picker-recent" title={t(E.pickerRecent)}>
                <EmptyIcon name="clock" />
              </span>
            ) : null}
            {row.kind === "dir" ? (
              <span className="ve-picker-chevron">
                <EmptyIcon name="chevron" />
              </span>
            ) : null}
          </>
        )}
        after={
          rows.length > shown.length ? (
            <div className="ve-picker-more">{strings.format(E.pickerMore, String(rows.length - shown.length))}</div>
          ) : null
        }
      />
      <div className="ve-picker-foot">
        <span className="ve-picker-hints" aria-hidden="true">
          <span className="ve-hint">
            <kbd>Tab</kbd>
            {t(E.pickerHintOpen)}
          </span>
          <span className="ve-hint">
            <kbd>⌘↑</kbd>
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
    </section>
  );
}

/** The picker as a modal sheet over the page: Escape (on an empty query) or a press outside cancels. */
export function PathPickerDialog(props: PathPickerProps) {
  const { t } = props.strings;
  return (
    <Dialog
      open
      onOpenChange={(open) => !open && props.onCancel()}
      label={props.labels?.title ?? t(props.mode === "folder" ? E.pickerFolderTitle : E.pickerFileTitle)}
      className="ve-sheet-dialog"
      backdropClassName="ve-sheet"
    >
      <PathPicker {...props} />
    </Dialog>
  );
}

// The in-page folder and file picker. The dev server answers `cmux.diff.chooseFolder` and
// `cmux.markdown.chooseFile` with it. It behaves as the app's palette picker (R89,
// plans/cmux-next/picker.md; PICKER-PATHS); pickerModel.ts has the rules, ui/drillKeys.ts the keys:
//   - one folder level at a time, recent folders first, git repositories marked;
//   - no jump keys: typing always filters the level (prefix matches first in Finder order, then
//     fuzzy matches by score); a query starting with "." also lists hidden entries;
//   - path mode: a query starting with "/" or "~/" lists the typed folder's entries that complete
//     the last segment (case-insensitive prefix; dot entries only after "."). Tab or the
//     inline-end arrow completes the segment (a folder ends with "/"); Return goes there, or
//     chooses a file; with an empty segment the first row is "Go to <folder>". Losing the prefix
//     returns to the folder's filter; Escape clears the query, a second Escape closes;
//   - Locations at the start folder with an empty query: Recent (a page of the recent items),
//     then the host's places (`cmux.picker.locations`: workspace folders, Home, Desktop,
//     Documents, Downloads, iCloud Drive, `picker.pinned`);
//   - Tab or the inline-end arrow enters a folder; Cmd-Up, the inline-start arrow at the start, or
//     Backspace on an empty query goes up; Return chooses (a folder in folder mode; a file, or
//     enters a folder, in the file modes); the breadcrumb navigates.
// The widget (roles, keys, highlight, announcements) is ui/DrillList; this file is the model glue.
import { useRef, useState } from "react";
import type { Strings } from "../pages/shared/i18n";
import { Breadcrumbs } from "../ui/Breadcrumbs";
import { Dialog } from "../ui/Dialog";
import { DrillList, type DrillSection } from "../ui/DrillList";
import { EmptyIcon, type EmptyIconName } from "./icons";
import { baseName, isMarkdownName, isPickerListing, tildePath, type PickerListing, type PickerMode } from "./ops";
import {
  PICKER_ROW_LIMIT,
  breadcrumb,
  completedQuery,
  folderQuery,
  parentPath,
  parsePickerPlaces,
  pathCompletions,
  pathQuery,
  pickerRows,
  recentPathSet,
  standardPlaces,
  type PickerPlace,
  type PickerPlaceKind,
  type PickerRow,
} from "./pickerModel";
import { fuzzyFilter } from "./fuzzy";
import { E } from "./strings";

export type PickerList = (path: string | null, options: { mode: PickerMode; hidden: boolean }) => Promise<unknown>;

export interface PathPickerProps {
  mode: PickerMode;
  list: PickerList;
  /** `cmux.picker.locations {}`: the Locations places. Without it, Home and its standard folders. */
  locations?: () => Promise<unknown>;
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

/** One row of the list: an entry, a place, the Recent page, a recent item, or "Go to". */
type Row =
  | { kind: "dir" | "file"; name: string; path: string; git?: boolean; recent?: boolean; row: "entry" }
  | { kind: "dir"; name: string; path: string; row: "place"; place: PickerPlaceKind }
  | { kind: "dir"; name: string; path: string; row: "recents" }
  | { kind: "dir" | "file"; name: string; path: string; row: "recent" }
  | { kind: "dir"; name: string; path: string; row: "go" };

const rowKey = (row: Row) => `${row.row}:${row.path}`;

const PLACE_ICONS: Record<PickerPlaceKind, EmptyIconName> = {
  workspace: "repo",
  home: "home",
  desktop: "folder",
  documents: "folder",
  downloads: "folder",
  iCloudDrive: "folder",
  pinned: "folder",
};

export function PathPicker({
  mode,
  list,
  locations: listLocations,
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
  // The highlighted row by key, so a new listing (or the Locations above it) keeps it in place.
  const [highlightKey, setHighlightKey] = useState<string | null>(null);
  // The folder the picker opened at (Locations show there) and the one path mode started from.
  const [startPath, setStartPath] = useState<string | null>(null);
  const [origin, setOrigin] = useState<string | null>(null);
  const [recentView, setRecentView] = useState(false);
  const [places, setPlaces] = useState<PickerPlace[] | null>(null);
  const request = useRef(0);
  const started = useRef(false);
  // Whether the shown listing includes hidden entries (a "." query asked for them).
  const listedHidden = useRef(false);
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
    listedHidden.current = options.hidden ?? false;
    setListing(value);
    setStartPath((first) => first ?? value.path);
    setLoad({ phase: "ready" });
    const rows = pickerRows(value.entries, options.hidden ? "." : "", mode, recentSet);
    const focus = options.focus ? rows.find((row) => row.path === options.focus) : undefined;
    setHighlightKey(focus ? `entry:${focus.path}` : null);
  };

  // A callback ref: the first listing and the Locations load when the picker mounts.
  const mountRef = (element: HTMLElement | null) => {
    if (!element || started.current) return;
    started.current = true;
    void navigate(start);
    void (listLocations?.() ?? Promise.resolve(null)).then(
      (value) => setPlaces(value == null ? null : parsePickerPlaces(value)),
      () => setPlaces(null),
    );
  };

  const placeName = (place: PickerPlace) =>
    ({
      home: t(E.pickerHome),
      desktop: t(E.pickerDesktop),
      documents: t(E.pickerDocuments),
      downloads: t(E.pickerDownloads),
      iCloudDrive: t(E.pickerICloudDrive),
      workspace: baseName(place.path),
      pinned: baseName(place.path),
    })[place.kind];

  const path = pathQuery(query, home);
  const filter = path ? path.rest : query;
  const levelRows = listing ? pickerRows(listing.entries, filter.startsWith(".") ? "." : "", mode, recentSet) : [];
  const asEntry = (row: PickerRow): Row => ({ ...row, row: "entry" });

  // The rows of the view: the Recent page, path mode, or the level with Locations at the start.
  let sections: DrillSection<Row>[];
  if (recentView) {
    const items: Row[] = recents
      .filter((item) => mode === "folder" || mode === "anyFile" || isMarkdownName(item))
      .map((item) => ({ kind: mode === "folder" ? "dir" : "file", name: baseName(item), path: item, row: "recent" }));
    sections = [{ id: "recent", items: fuzzyFilter(items, query, (row) => row.name) }];
  } else if (path) {
    const go: Row[] =
      path.rest === ""
        ? [{ kind: "dir", name: strings.format(E.pickerGoTo, path.typed), path: path.dir, row: "go" }]
        : [];
    sections = [
      { id: "go", items: go },
      { id: "level", items: pathCompletions(levelRows, path.rest).slice(0, PICKER_ROW_LIMIT).map(asEntry) },
    ];
  } else {
    const atStart = query === "" && listing !== null && listing.path === startPath;
    const placeRows: Row[] = atStart
      ? [
          ...(recents.length
            ? [{ kind: "dir" as const, name: t(E.pickerRecent), path: "recent:", row: "recents" as const }]
            : []),
          ...(places ?? standardPlaces(home)).map((place) => ({
            kind: "dir" as const,
            name: placeName(place),
            path: place.path,
            row: "place" as const,
            place: place.kind,
          })),
        ]
      : [];
    const filtered = listing ? pickerRows(listing.entries, query, mode, recentSet) : [];
    sections = [
      { id: "locations", label: t(E.pickerLocations), items: placeRows },
      { id: "level", items: filtered.slice(0, PICKER_ROW_LIMIT).map(asEntry) },
    ];
  }
  const level = sections.at(-1)!.items;
  const all = sections.flatMap((section) => section.items);
  const unshown =
    !recentView && !path && listing ? pickerRows(listing.entries, query, mode, recentSet).length - level.length : 0;
  const found = all.findIndex((row) => rowKey(row) === highlightKey);
  // Default: the first row of the level (or "Go to"); none in an empty level (Enter then chooses
  // the folder in folder mode).
  const highlight =
    found >= 0 ? found : sections[0].id === "go" && all.length ? 0 : level.length ? all.length - level.length : -1;

  /** Shows `target` with an empty query (leaves path mode and the Recent page). */
  const go = (target: string | null, focus?: string) => {
    setQuery("");
    setOrigin(null);
    setRecentView(false);
    // Path mode already listed this folder ("Go to", Return on a completed path): keep it.
    if (target !== null && target === listing?.path && load.phase === "ready" && !listedHidden.current && !focus) {
      return setHighlightKey(null);
    }
    void navigate(target, { focus });
  };
  const goUp = () => {
    if (recentView) return go(startPath);
    if (!listing) return;
    const parent = listing.parent ?? parentPath(listing.path);
    if (!parent) return;
    if (path) {
      // Path mode follows the folder: the field shows the parent's path.
      setQuery(folderQuery(parent, home));
      return void navigate(parent, { focus: listing.path });
    }
    go(parent, listing.path);
  };
  /** Tab or the inline-end arrow: enter a folder, open a place or the Recent page, complete a path. */
  const enter = (row: Row | undefined) => {
    if (!row) return;
    if (row.row === "recents") {
      setQuery("");
      setHighlightKey(null);
      return setRecentView(true);
    }
    if (path && row.row === "entry") return setQueryValue(completedQuery(path, row));
    if (row.kind === "dir" && row.row !== "go") go(row.path);
  };
  /** Return: go to the folder (path mode, places), choose, or enter in the file modes. */
  const choose = (row: Row | undefined) => {
    if (!row) {
      // Folder mode with nothing to highlight (an empty folder, no subfolders) chooses the folder.
      if (mode === "folder" && query === "" && listing && load.phase === "ready" && !recentView) onChoose(listing.path);
      return;
    }
    if (row.row === "recents") return enter(row);
    if (row.row === "go" || row.row === "place" || (path && row.kind === "dir")) return go(row.path);
    // The file modes enter folders; folder mode chooses one.
    if (row.kind === "dir" && mode !== "folder") return go(row.path);
    onChoose(row.path);
  };

  const setQueryValue = (value: string) => {
    const before = pathQuery(query, home);
    const next = pathQuery(value, home);
    const hiddenBefore = (before ? before.rest : query).startsWith(".");
    const hidden = (next ? next.rest : value).startsWith(".");
    setQuery(value);
    setHighlightKey(null);
    if (recentView) return;
    if (next && !before) setOrigin(listing?.path ?? null);
    if (next && next.dir !== listing?.path) {
      void navigate(next.dir, { hidden });
    } else if (!next && before) {
      // The query lost its path prefix: back to the folder path mode started from, filtered.
      const back = origin ?? listing?.path ?? null;
      setOrigin(null);
      if (back !== listing?.path || hidden !== hiddenBefore) void navigate(back, { hidden });
    } else if (hidden !== hiddenBefore && listing) {
      void navigate(listing.path, { hidden });
    }
  };

  const title = labels?.title ?? t(mode === "folder" ? E.pickerFolderTitle : E.pickerFileTitle);
  const crumbs = listing ? breadcrumb(listing.path, listing.home) : [];
  const shownCrumbs = recentView ? [...crumbs, { label: t(E.pickerRecent), path: "recent:" }] : crumbs;
  const emptyText =
    load.phase === "failed"
      ? t(E.pickerFailed)
      : load.phase === "loading" && !listing
        ? t(E.pickerLoading)
        : path && path.rest !== ""
          ? strings.format(E.pickerNoMatch, path.typed)
          : filter !== "" || recentView
            ? t(E.pickerNoMatches)
            : (labels?.empty ?? t(mode === "folder" ? E.pickerEmptyFolder : E.pickerEmptyFile));
  const status =
    load.phase === "failed"
      ? t(E.pickerFailed)
      : load.phase === "loading"
        ? t(E.pickerLoading)
        : listing
          ? strings.format(
              E.pickerStatus,
              recentView ? t(E.pickerRecent) : tildePath(listing.path, listing.home),
              String(level.length),
            )
          : "";
  const icon = (row: Row): EmptyIconName => {
    if (row.row === "recents") return "clock";
    if (row.row === "place") return PLACE_ICONS[row.place];
    if (row.kind === "file") return "file";
    return row.row === "entry" && row.git ? "repo" : "folder";
  };

  return (
    <section ref={mountRef} className="ve-picker" data-mode={mode} data-phase={load.phase} aria-label={title}>
      <div className="ve-picker-head">
        <span className="ve-picker-title">{title}</span>
        <Breadcrumbs
          className="ve-crumbs"
          crumbClassName="ve-crumb"
          label={t(E.pickerLocation)}
          crumbs={shownCrumbs}
          separator={(index) => (shownCrumbs[index - 1].label !== "/" ? <span className="ve-crumb-sep">/</span> : null)}
          onNavigate={(crumb, index) =>
            crumb.path === "recent:" ? undefined : go(crumb.path, shownCrumbs[index + 1]?.path)
          }
        />
      </div>
      <DrillList<Row>
        sections={sections}
        getKey={rowKey}
        highlight={highlight}
        onHighlight={(index) => setHighlightKey(all[index] ? rowKey(all[index]) : null)}
        query={query}
        onQueryChange={setQueryValue}
        onEnter={enter}
        onUp={goUp}
        onChoose={choose}
        onCancel={onCancel}
        onActivate={(row) => (row.kind === "dir" && !path ? enter(row) : choose(row))}
        label={t(E.pickerPlaceholder)}
        placeholder={t(E.pickerPlaceholder)}
        listLabel={recentView ? t(E.pickerRecent) : (listing?.path ?? t(E.pickerLoading))}
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
          title: row.row === "recents" ? undefined : row.path,
          "data-kind": row.kind,
          "data-row": row.row,
          "data-location": row.row === "place" || row.row === "recents" ? "true" : undefined,
          "data-git": row.row === "entry" && row.git ? "true" : undefined,
          "data-recent": row.row === "entry" && row.recent ? "true" : undefined,
        })}
        renderItem={(row) => (
          <>
            <EmptyIcon name={icon(row)} title={row.row === "entry" && row.git ? t(E.pickerGit) : undefined} />
            <span className={row.row === "place" || row.row === "recents" ? "ve-picker-location" : "ve-picker-name"}>
              {path && row.row === "entry" && row.kind === "dir" ? `${row.name}/` : row.name}
            </span>
            {row.row === "entry" && row.recent ? (
              <span className="ve-picker-recent" title={t(E.pickerRecent)}>
                <EmptyIcon name="clock" />
              </span>
            ) : null}
            {row.kind === "dir" && row.row !== "go" ? (
              <span className="ve-picker-chevron">
                <EmptyIcon name="chevron" />
              </span>
            ) : null}
          </>
        )}
        after={
          unshown > 0 ? <div className="ve-picker-more">{strings.format(E.pickerMore, String(unshown))}</div> : null
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

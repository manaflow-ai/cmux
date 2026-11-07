import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useT } from "./i18n";
import {
  browseCrumbs,
  FolderBrowse,
  opensAsFolder,
  type BrowseEntry,
  type BrowseFailure,
  type BrowseFolders,
  type BrowseView,
} from "./folderBrowse";

/// How the browser names where it is (gallery `agent-pane.remote-folder-browser`): `title`, the
/// folder's name over its path with an Up button (shipped: one header row at every width, the dock's
/// 240 px included); `crumbs`, a breadcrumb of every folder from the top; `field`, the path as an
/// editable field.
export type BrowserLook = "title" | "crumbs" | "field";

/// A machine's folders, browsed one directory at a time inside the folder menu (folderBrowse.ts).
/// The menu keeps the size it had (`size`), so switching from its list to the browser and back moves
/// nothing; rows are reserved while a folder loads, so its answer never pushes the footer. Only the
/// rows in view mount; the next page is asked for near the end of the list. Use picks the folder
/// shown, the way a row of the menu's list does (`onPick`). Back (Escape, or Up at the top) returns
/// to the list.
export function RemoteFolderBrowser({
  machine,
  peer,
  list,
  start = null,
  size,
  look = "title",
  onPick,
  onBack,
}: {
  /// The machine's name, as the menu shows it.
  machine: string;
  /// Its acpmux peer; none: the page's own daemon.
  peer?: string;
  list: BrowseFolders;
  /// The folder it opens on; null: the machine's top (its start folders on a peer).
  start?: string | null;
  /// The menu's size when the browser opened; it keeps it.
  size?: { width: number; height: number };
  look?: BrowserLook;
  onPick(path: string): void;
  onBack(): void;
}) {
  const t = useT();
  const [view, setView] = useState<BrowseView>({
    path: start,
    parent: null,
    entries: [],
    loading: true,
    loadingMore: false,
  });
  const browse = useMemo(() => new FolderBrowse(list, peer, setView), [list, peer]);
  useEffect(() => {
    browse.open(start);
    return () => browse.dispose();
  }, [browse, start]);
  const [filter, setFilter] = useState("");
  const [highlight, setHighlight] = useState(0);
  const field = useRef<HTMLInputElement>(null);
  const scroller = useRef<HTMLDivElement>(null);
  useEffect(() => field.current?.focus(), []);
  const words = filter.trim().toLowerCase();
  const rows = useMemo(
    () =>
      view.entries.filter(
        (entry) => (opensAsFolder(entry) || entry.outside) && (!words || entry.name.toLowerCase().includes(words)),
      ),
    [view.entries, words],
  );
  const go = (path: string | null) => {
    setFilter("");
    setHighlight(0);
    if (scroller.current) scroller.current.scrollTop = 0;
    browse.open(path);
  };
  // Up from the machine's top goes back to the menu's list.
  const up = () => (view.path === null ? onBack() : go(view.parent));
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scroller.current,
    estimateSize: () => ROW,
    overscan: 8,
    initialRect: { width: 240, height: 240 },
  });
  // A DOM with no layout (jsdom, in tests) measures nothing: every row, as an unvirtualized list.
  const shown = noLayout()
    ? rows.map((_, index) => ({ index, start: index * ROW, key: index }))
    : virtualizer.getVirtualItems();
  const last = shown.at(-1)?.index ?? -1;
  // The next page near the end of what is in view; the model asks once per page.
  useEffect(() => {
    if (view.more !== undefined && last >= rows.length - PREFETCH_ROWS) browse.more();
  }, [browse, last, rows.length, view.more]);
  useLayoutEffect(() => {
    if (highlight >= rows.length) setHighlight(Math.max(0, rows.length - 1));
  }, [highlight, rows.length]);
  const open = (entry: BrowseEntry) => {
    if (opensAsFolder(entry)) go(entry.path);
  };
  const key = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onBack();
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const next = Math.min(rows.length - 1, Math.max(0, highlight + (event.key === "ArrowDown" ? 1 : -1)));
      setHighlight(next);
      virtualizer.scrollToIndex(next, { align: "auto" });
    } else if (event.key === "Enter") {
      event.preventDefault();
      // ⌘Return uses the folder shown; Return opens the highlighted one.
      if ((event.metaKey || event.ctrlKey) && view.path) onPick(view.path);
      else if (rows[highlight]) open(rows[highlight]!);
    } else if (event.key === "Backspace" && filter === "") {
      event.preventDefault();
      up();
    }
  };
  const name = view.path ? (view.path.split("/").filter(Boolean).at(-1) ?? "/") : machine;
  const failure = view.failure ? failureText(t, view.failure, machine) : undefined;
  return (
    <div
      className="acpmux-browse"
      data-look={look}
      data-loading={view.loading ? "" : undefined}
      style={{
        ...(size?.width ? { width: size.width } : {}),
        height: Math.max(size?.height ?? 0, MIN_HEIGHT),
      }}
    >
      <div className="acpmux-browse-head">
        <button
          type="button"
          className="acpmux-browse-up ui-ghost ui-ghost-sm"
          aria-label={t("composer.browseUp")}
          // tooltip-allow: an icon-only button's name.
          title={t("composer.browseUp")}
          onMouseDown={(event) => event.preventDefault()}
          onClick={up}
        >
          <ChevronLeftIcon />
        </button>
        {look === "crumbs" && view.path ? (
          <nav className="acpmux-browse-crumbs" aria-label={view.path}>
            {browseCrumbs(view.path, view.home).map((crumb, index, all) => (
              <React.Fragment key={crumb.path}>
                {index > 0 && <span aria-hidden="true">/</span>}
                <button
                  type="button"
                  className="acpmux-browse-crumb"
                  aria-current={index === all.length - 1 ? "location" : undefined}
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => go(crumb.path)}
                >
                  {crumb.name}
                </button>
              </React.Fragment>
            ))}
          </nav>
        ) : look === "field" && view.path ? (
          <PathField key={view.path} path={view.path} onGo={go} />
        ) : (
          // tooltip-allow: the header shows the folder's name; the tooltip is its full path
          <span className="acpmux-menu-text acpmux-browse-title" title={view.path ?? machine}>
            <span className="acpmux-menu-label">{name}</span>
            <span className="acpmux-menu-description">{view.path ?? t("composer.browseMachine", { machine })}</span>
          </span>
        )}
      </div>
      <input
        ref={field}
        className="acpmux-location-search acpmux-browse-filter"
        aria-label={t("composer.browseSearch")}
        placeholder={t("composer.browseSearch")}
        value={filter}
        onChange={(event) => {
          setFilter(event.target.value);
          setHighlight(0);
        }}
        onKeyDown={key}
      />
      <div ref={scroller} className="acpmux-browse-rows ui-scroll-edge-fade">
        {view.loading ? (
          // The rows' room is kept while the machine answers: the footer never moves under the pointer.
          <div className="acpmux-location-empty" role="status">
            {t("composer.browseLoading")}
          </div>
        ) : failure ? (
          <div className="acpmux-location-empty" role="alert">
            {failure}
          </div>
        ) : rows.length === 0 ? (
          <div className="acpmux-location-empty">{t(words ? "composer.folderNone" : "composer.browseEmpty")}</div>
        ) : (
          <div style={{ position: "relative", height: noLayout() ? undefined : virtualizer.getTotalSize() }}>
            {shown.map((item) => {
              const entry = rows[item.index]!;
              const outside = Boolean(entry.outside);
              return (
                <button
                  key={entry.path}
                  type="button"
                  aria-disabled={outside || undefined}
                  className="acpmux-menu-item acpmux-browse-row"
                  data-highlighted={item.index === highlight ? "" : undefined}
                  data-link={entry.kind === "symlink" ? "" : undefined}
                  style={
                    noLayout() ? undefined : { position: "absolute", top: 0, transform: `translateY(${item.start}px)` }
                  }
                  // tooltip-allow: the row shows the folder's name; the tooltip is its full path, or why it can't open
                  title={outside ? failureText(t, "outside", machine) : entry.path}
                  onMouseDown={(event) => event.preventDefault()}
                  onMouseEnter={() => setHighlight(item.index)}
                  onClick={() => open(entry)}
                >
                  <span className="acpmux-location-action-icon" aria-hidden="true">
                    <FolderGlyph link={entry.kind === "symlink"} />
                  </span>
                  <span className="acpmux-menu-label">{entry.name}</span>
                  {!outside && (
                    <span className="acpmux-browse-chevron" aria-hidden="true">
                      <ChevronRightIcon />
                    </span>
                  )}
                </button>
              );
            })}
          </div>
        )}
      </div>
      {view.truncated && <p className="acpmux-location-note acpmux-browse-note">{t("composer.browseTruncated")}</p>}
      <hr className="ui-separator" />
      <button
        type="button"
        className="acpmux-menu-item acpmux-location-choose acpmux-browse-use"
        disabled={!view.path || view.loading || Boolean(view.failure)}
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => view.path && onPick(view.path)}
      >
        {t("composer.browseUse", { name: view.path ? name : machine })}
      </button>
    </div>
  );
}

/// The `field` look: the path itself, edited; Return goes there.
function PathField({ path, onGo }: { path: string; onGo(path: string): void }) {
  const [value, setValue] = useState(path);
  return (
    <input
      className="acpmux-browse-path"
      aria-label={path}
      value={value}
      spellCheck={false}
      onChange={(event) => setValue(event.target.value)}
      onKeyDown={(event) => {
        if (event.key !== "Enter") return;
        event.preventDefault();
        const next = value.trim();
        if (next.startsWith("/")) onGo(next);
      }}
    />
  );
}

function failureText(t: ReturnType<typeof useT>, failure: BrowseFailure, machine: string): string {
  switch (failure) {
    case "unsupported":
      return t("composer.browseUnsupported", { machine });
    case "outside":
      return t("composer.browseOutside", { machine });
    case "unreachable":
      return t("composer.browseUnreachable", { machine });
    default:
      return t("composer.browseFailed");
  }
}

/// A row's height before it is measured: the menu's row.
const ROW = 28;
/// The browser is never shorter than this, also when the list it replaced was (one known folder).
const MIN_HEIGHT = 220;
/// Rows from the end at which the next page is asked for.
const PREFETCH_ROWS = 40;

/// Read at render, not at import: a test installs its DOM's `navigator` after the modules load.
const noLayout = () => typeof navigator !== "undefined" && navigator.userAgent.includes("jsdom");

function FolderGlyph({ link }: { link: boolean }) {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.6l1.4 1.5h5A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z" />
      {link && <path d="M7 10.5 10 7.5M8 7.5h2v2" />}
    </svg>
  );
}

function ChevronLeftIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M10 3.5 5.5 8l4.5 4.5" />
    </svg>
  );
}

function ChevronRightIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="m6 3.5 4.5 4.5L6 12.5" />
    </svg>
  );
}

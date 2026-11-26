// The Files section of the selected machine (files.ts). Nothing is read until Browse. Folders open on
// click; a file click previews a small text file, which Edit turns into a field that Save writes back.
// Delete, Upload and Download go to the host (native confirmation or file panel); the page never
// calls `fs.remove`, `file.push` or `file.pull` itself. A push or pull shows as a transfer row that
// is running until its `file.transfer.changed` event; a busy refusal shows a message with Retry
// (retry-prompt-ok: it runs the push or pull again, which opens the host's file panel again). A
// machine whose daemon has no file ops yet (`fs-v1`) shows "Not available yet" for that machine.
import { memo, useCallback, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { useStableHandlers } from "../../agent-session/acpmux/stableHandlers";
import { formatBytes, plainKeys, type SectionProps } from "./sectionParts";
import { joinPath } from "./files";
import { CloudOps, type FsEntry } from "./ops";
import { format, L } from "./strings";
import type { FileTransfer } from "./transfers";

const TRANSFER_LABEL = {
  running: L.transferRunning,
  done: L.transferDone,
  failed: L.transferFailed,
  cancelled: L.transferCancelled,
} as const;

function Transfers({ transfers, strings }: { transfers: readonly FileTransfer[]; strings: SectionProps["strings"] }) {
  const { t } = strings;
  if (!transfers.length) return null;
  return (
    <>
      <h4 className="cloud-subsection-title">{t(L.transfers)}</h4>
      <ul className="cloud-items cloud-transfers">
        {transfers.map((transfer) => (
          <li key={transfer.transfer} className={`cloud-item cloud-transfer kind-${transfer.direction}`}>
            <span className="cloud-item-title cloud-mono">{transfer.path}</span>
            <span className="cloud-item-detail">
              {transfer.state === "done" && transfer.bytes != null ? formatBytes(transfer.bytes, strings) : ""}
            </span>
            <span
              className={`cloud-transfer-state state-${transfer.state}`}
              /* tooltip-allow: the failure's detail, shown nowhere else */ title={transfer.error}
            >
              {t(TRANSFER_LABEL[transfer.state])}
            </span>
          </li>
        ))}
      </ul>
    </>
  );
}

function Preview({ store, detail, strings }: Pick<SectionProps, "store" | "detail" | "strings">) {
  const { t } = strings;
  const preview = detail.files?.preview;
  const [draft, setDraft] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const savingNow = useRef(false);
  const draftRevision = useRef(0);
  const updateDraft = (next: string | null) => {
    draftRevision.current += 1;
    setDraft(next);
  };
  if (!preview) return null;
  const body = () => {
    if (preview.tooLarge)
      return <p className="cloud-muted">{format(t(L.filesTooLarge), { size: formatBytes(preview.size, strings) })}</p>;
    if (preview.binary) return <p className="cloud-muted">{t(L.filesBinary)}</p>;
    if (preview.unread) return <p className="cloud-muted">{t(L.filesNoPreview)}</p>;
    if (draft !== null)
      return (
        <textarea
          className="cloud-input cloud-file-editor cloud-mono"
          aria-label={preview.path}
          value={draft}
          // Unsaved text: app health never reloads the page away from it (pageHealth.ts).
          data-cmux-unsaved-edits={draft === preview.text ? undefined : ""}
          onChange={(event) => updateDraft(event.target.value)}
        />
      );
    return <pre className="cloud-file-preview cloud-mono">{preview.text}</pre>;
  };
  const save = () => {
    if (draft === null || savingNow.current) return;
    const submittedRevision = draftRevision.current;
    savingNow.current = true;
    setSaving(true);
    // Typing stays available during a write. Only its submitted edit may close on success;
    // a newer edit (including Cancel followed by Edit) belongs to the next save.
    void store.files
      .save(preview.path, draft)
      .then((saved) => {
        if (saved && submittedRevision === draftRevision.current) setDraft(null);
      })
      .finally(() => {
        savingNow.current = false;
        setSaving(false);
      });
  };
  return (
    <div className="cloud-file-view">
      <div className="cloud-subsection-header">
        <span className="cloud-item-title cloud-mono">{preview.path}</span>
        <span className="cloud-item-actions">
          {preview.text !== undefined && draft === null && (
            <button
              type="button"
              className="cloud-link-button cloud-file-edit"
              onClick={() => updateDraft(preview.text ?? "")}
            >
              {t(L.filesEdit)}
            </button>
          )}
          {draft !== null && (
            <>
              <button type="button" className="cloud-link-button" onClick={() => updateDraft(null)}>
                {t(L.cancel)}
              </button>
              <button type="button" className="cloud-link-button cloud-file-save" disabled={saving} onClick={save}>
                {t(L.save)}
              </button>
            </>
          )}
          {draft === null && (
            <button type="button" className="cloud-link-button" onClick={() => store.files.closePreview()}>
              {t(L.filesClosePreview)}
            </button>
          )}
        </span>
      </div>
      {body()}
    </div>
  );
}

function NewFolder({ store, t }: { store: SectionProps["store"]; t: (key: string) => string }) {
  const [name, setName] = useState("");
  const submit = () => {
    if (!name.trim()) return;
    void store.files.mkdir(name);
    setName("");
  };
  return (
    <span className="cloud-inline-form">
      <input
        className="cloud-input cloud-folder-name"
        placeholder={t(L.filesNewFolder)}
        aria-label={t(L.filesNewFolder)}
        value={name}
        onChange={(event) => setName(event.target.value)}
        onKeyDown={plainKeys(submit)}
      />
      <button
        type="button"
        className="cloud-button cloud-folder-add"
        aria-label={t(L.filesNewFolder)}
        aria-disabled={!name.trim()}
        onClick={submit}
      >
        +
      </button>
    </span>
  );
}

/** A row's height before the first one is measured (one line of link buttons, 4 px padding). */
const ROW_ESTIMATE = 29;
/** At least this many rows above and below the visible ones; else one viewport each side. */
const MIN_OVERSCAN = 8;

/** The closest element above `node` that scrolls vertically: the page's body. */
function scrollParentOf(node: HTMLElement): HTMLElement {
  for (let at = node.parentElement; at; at = at.parentElement) {
    const overflow = at.ownerDocument.defaultView?.getComputedStyle(at).overflowY;
    if (overflow === "auto" || overflow === "scroll" || overflow === "overlay") return at;
  }
  return node;
}

/**
 * A folder's entries, mounting only those near the viewport (the visible-only rule): a folder has no
 * size cap, and every entry used to be a mounted row. The rows window (TanStack Virtual) against the
 * page body that scrolls them, from where the list starts in it (scrollMargin): about one viewport
 * each side, in the flow between two blocks standing in for the rest. Rows are memoized on their
 * entry with stable handlers, so a scroll draws only the rows it brings in and a relisting only the
 * rows that changed. The row that has focus, its neighbours and the first and last rows stay mounted,
 * so the browser's own Tab and Shift-Tab go to the next row in list order (and into the list at its
 * first or last entry), each focused row scrolling into view. No row is selected or deep-linked.
 */
function FileRows({
  store,
  entries,
  folder,
  canPull,
  canRemove,
  strings,
}: {
  store: SectionProps["store"];
  entries: readonly FsEntry[];
  folder: string;
  canPull: boolean;
  canRemove: boolean;
  strings: SectionProps["strings"];
}) {
  const { t } = strings;
  const list = useRef<HTMLUListElement>(null);
  const viewport = useRef<HTMLElement | null>(null);
  const findViewport = useCallback(() => {
    if (!viewport.current && list.current) viewport.current = scrollParentOf(list.current);
    return viewport.current;
  }, []);

  // Where the rows start in the body's content, and one viewport of rows. They move only when a box
  // between the list and the body resizes (a machine's sections loading above it), never on a scroll.
  const [scrollMargin, setScrollMargin] = useState(0);
  const [viewportHeight, setViewportHeight] = useState(0);
  const measureMargin = useCallback(() => {
    const scroller = findViewport();
    const start = list.current;
    if (!scroller || !start || scroller === start) return;
    const next =
      start.getBoundingClientRect().top -
      scroller.getBoundingClientRect().top +
      scroller.scrollTop -
      scroller.clientTop;
    setScrollMargin((previous) => (previous === next ? previous : next));
    setViewportHeight(scroller.clientHeight);
  }, [findViewport]);
  useLayoutEffect(() => {
    measureMargin();
    const scroller = findViewport();
    if (!scroller || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measureMargin);
    for (let node: HTMLElement | null = list.current; node; node = node.parentElement) {
      observer.observe(node);
      // Its siblings above it in each box move it too (the sections above, the account rail's wrap).
      for (let sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling)
        observer.observe(sibling);
      if (node === scroller) break;
    }
    return () => observer.disconnect();
  }, [findViewport, measureMargin]);

  const pathOf = useCallback((entry: FsEntry) => entry.path ?? joinPath(folder, entry.name ?? ""), [folder]);
  // An entry's place by its path, built once per listing: focus finds its row without a scan.
  const indexOf = useMemo(() => new Map(entries.map((entry, index) => [pathOf(entry), index])), [entries, pathOf]);
  const [focused, setFocused] = useState<string | undefined>(undefined);
  const focusedIndex = focused === undefined ? -1 : (indexOf.get(focused) ?? -1);

  // One function per listing: TanStack measures every row again when it changes.
  const rowKey = useCallback((at: number) => pathOf(entries[at]!), [entries, pathOf]);
  // The first measured row sizes every row not yet mounted.
  const rowHeight = useRef(0);
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns a mutable instance, so the React Compiler skips this component, as in ui/VirtualList.
  const virtualizer = useVirtualizer({
    count: entries.length,
    getScrollElement: findViewport,
    scrollMargin,
    estimateSize: () => rowHeight.current || ROW_ESTIMATE,
    getItemKey: rowKey,
    overscan: Math.max(MIN_OVERSCAN, Math.ceil(viewportHeight / (rowHeight.current || ROW_ESTIMATE))),
    // The row with focus stays mounted, so a scroll away never drops focus to the page; so do its
    // neighbours and the first and last rows, the browser's next tab stops: Tab and Shift-Tab go on
    // in list order, and into the list at its first or last entry.
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      const kept = [0, entries.length - 1];
      if (focusedIndex >= 0) kept.push(focusedIndex - 1, focusedIndex, focusedIndex + 1);
      for (const index of kept)
        if (index >= 0 && index < entries.length && !indexes.includes(index)) indexes.push(index);
      return indexes.sort((a, b) => a - b);
    },
  });
  const measure = useCallback(
    (node: HTMLElement | null) => {
      if (node && !rowHeight.current && node.offsetHeight > 0) rowHeight.current = node.offsetHeight;
      virtualizer.measureElement(node);
    },
    [virtualizer],
  );

  // A row's index moves when entries come or go above it. Its row keeps its props (the index is not
  // one it draws again for) and is told here, so TanStack measures the right entry on a resize.
  useLayoutEffect(() => {
    for (const [key, node] of virtualizer.elementsCache) {
      const at = indexOf.get(String(key));
      if (at !== undefined && node.getAttribute("data-index") !== String(at))
        node.setAttribute("data-index", String(at));
    }
  }, [virtualizer, indexOf]);

  // One function per handler for every render: a memo row draws again only when its own props change.
  const handlers = useStableHandlers({
    onOpen: (path: string, isFolder: boolean) => void (isFolder ? store.files.open(path) : store.files.preview(path)),
    onPull: (path: string) => void store.files.pull(path),
    onRemove: (path: string) => void store.files.remove(path),
  });
  const labels = { folder: t(L.filesFolder), download: t(L.filesDownload), remove: t(L.delete) };

  const children: ReactNode[] = [];
  let reached = scrollMargin;
  let previous = -1;
  const gap = (height: number) => {
    if (height > 0) children.push(<li key={`\u0000gap:${previous}`} aria-hidden="true" style={{ height }} />);
  };
  for (const { index, start, end } of virtualizer.getVirtualItems()) {
    gap(start - reached);
    reached = end;
    previous = index;
    const entry = entries[index]!;
    const isFolder = entry.kind === "directory";
    children.push(
      <FileRow
        key={pathOf(entry)}
        index={index}
        count={entries.length}
        measure={measure}
        entry={entry}
        path={pathOf(entry)}
        detail={isFolder ? labels.folder : entry.size != null ? formatBytes(entry.size, strings) : ""}
        downloadLabel={entry.kind === "file" && canPull ? labels.download : undefined}
        removeLabel={canRemove ? labels.remove : undefined}
        {...handlers}
      />,
    );
  }
  gap(virtualizer.getTotalSize() + scrollMargin - reached);

  return (
    <ul
      ref={list}
      className="cloud-items cloud-files"
      onFocus={(event) => {
        const row = (event.target as Element).closest<HTMLElement>("[data-path]");
        setFocused(row?.dataset.path);
      }}
    >
      {children}
    </ul>
  );
}

interface FileRowProps {
  index: number;
  count: number;
  measure: (node: HTMLElement | null) => void;
  entry: FsEntry;
  path: string;
  detail: string;
  /** Absent: no Download (a folder, or the owner cannot pull). */
  downloadLabel?: string;
  removeLabel?: string;
  onOpen: (path: string, isFolder: boolean) => void;
  onPull: (path: string) => void;
  onRemove: (path: string) => void;
}

/** Equal props but for `index`: the list sets a moved row's attribute itself. */
function sameRow(before: FileRowProps, after: FileRowProps): boolean {
  const keys = Object.keys(after) as (keyof FileRowProps)[];
  return (
    keys.length === Object.keys(before).length &&
    keys.every((key) => key === "index" || Object.is(before[key], after[key]))
  );
}

const FileRow = memo(function FileRow({
  index,
  count,
  measure,
  entry,
  path,
  detail,
  downloadLabel,
  removeLabel,
  onOpen,
  onPull,
  onRemove,
}: FileRowProps) {
  const isFolder = entry.kind === "directory";
  return (
    <li
      ref={measure}
      data-index={index}
      data-path={path}
      className={`cloud-item cloud-file kind-${entry.kind}`}
      aria-posinset={index + 1}
      aria-setsize={count}
    >
      <button
        type="button"
        className="cloud-link-button cloud-file-name cloud-mono"
        onClick={() => onOpen(path, isFolder)}
      >
        {entry.name ?? path}
      </button>
      <span className="cloud-item-detail">{detail}</span>
      <span className="cloud-item-actions">
        {downloadLabel !== undefined && (
          <button type="button" className="cloud-link-button cloud-file-download" onClick={() => onPull(path)}>
            {downloadLabel}
          </button>
        )}
        {removeLabel !== undefined && (
          <button
            type="button"
            className="cloud-link-button destructive cloud-file-remove"
            onClick={() => onRemove(path)}
          >
            {removeLabel}
          </button>
        )}
      </span>
    </li>
  );
}, sameRow);

export function FilesSection({
  store,
  detail,
  unavailable,
  transfers,
  strings,
}: Omit<SectionProps, "machine"> & { transfers: readonly FileTransfer[] }) {
  const { t } = strings;
  const files = detail.files;
  const off = unavailable.includes(CloudOps.fsList) || !!files?.unavailable;
  const rows = <Transfers transfers={transfers.filter((item) => item.machine === detail.machine)} strings={strings} />;
  const header = (
    <div className="cloud-subsection-header">
      <h3 className="cloud-subsection-title">{t(L.files)}</h3>
      {!files && !off && (
        <button type="button" className="cloud-link-button cloud-files-browse" onClick={() => void store.files.open()}>
          {t(L.filesBrowse)}
        </button>
      )}
    </div>
  );
  if (off)
    return (
      <>
        {header}
        <p className="cloud-muted cloud-unavailable">{t(L.unavailable)}</p>
      </>
    );
  if (!files)
    return (
      <>
        {header}
        {rows}
      </>
    );
  return (
    <>
      {header}
      <div className="cloud-files-bar">
        <button
          type="button"
          className="cloud-link-button cloud-files-up"
          disabled={files.path === "/"}
          onClick={() => void store.files.up()}
        >
          {t(L.filesUp)}
        </button>
        <code className="cloud-mono cloud-files-path">{files.path}</code>
        <NewFolder store={store} t={t} />
        {!unavailable.includes(CloudOps.filePush) && (
          <button
            type="button"
            className="cloud-link-button cloud-files-upload"
            onClick={() => void store.files.push()}
          >
            {t(L.filesUpload)}
          </button>
        )}
      </div>
      {/* retry-prompt-ok: nothing ran; running it again opens the host's native file panel, so it is the person's. */}
      {files.busy && (
        <p className="cloud-muted cloud-transfer-busy">
          {t(L.transferBusy)}{" "}
          <button
            type="button"
            className="cloud-link-button cloud-transfer-retry"
            onClick={() => void store.files.retryTransfer()}
          >
            {t(L.retry)}
          </button>
        </p>
      )}
      {rows}
      {files.entries?.length ? (
        <FileRows
          store={store}
          entries={files.entries}
          folder={files.path}
          canPull={!unavailable.includes(CloudOps.filePull)}
          canRemove={!unavailable.includes(CloudOps.fsRemove)}
          strings={strings}
        />
      ) : (
        <p className="cloud-muted">{files.loading ? t(L.loading) : t(L.filesEmpty)}</p>
      )}
      <Preview key={files.preview?.path} store={store} detail={detail} strings={strings} />
    </>
  );
}

// Stacked per-file diffs (@pierre/diffs) with Codex's custom file header. Files with full
// texts use MultiFileDiff (Pierre computes the hunks); files given as a patch use PatchDiff.
import { useMemo, useRef, type ReactNode } from "react";
import { MultiFileDiff, PatchDiff, useStableCallback } from "@pierre/diffs-port/react";
import { CODEX_DIFF_THEME } from "../theme";
import { diffUnsafeCSS } from "../diffStyles";
import { HEADER_LABELS } from "../constants";
import * as I from "../icons";
import type { ChangedFile, FileHeaderButtonId } from "../model";
import { useOverlayThumb } from "../OverlayScrollbar";
import { Counts } from "./Header";
import { FileTypeIcon } from "./FileTypeIcon";
import { anchorProps } from "./TopLayer";

const HEADER_ICONS: Record<FileHeaderButtonId, ReactNode> = {
  viewed: <I.Eye />,
  "open-tab": <I.OpenTab width={14} height={14} />,
  "open-editor": <I.CodeIcon />,
  actions: <I.Dots />,
};
const HEADER_BUTTONS = Object.keys(HEADER_ICONS) as FileHeaderButtonId[];

/** Per-file view state derived from the pane state. */
export interface FileView {
  collapsed: boolean;
  viewed: boolean;
  /** Pointer over the header (filename chevron), and over which button. */
  hovered: boolean;
  hoveredButton?: FileHeaderButtonId;
  /** File actions menu open: the ⋯ button stays lit. */
  menuOpen: boolean;
  /** Initial horizontal scroll of the code area, CSS px. */
  scrollLeft?: number;
}

/** Per-file interactions. */
export interface FileHandlers {
  hover(path: string, button?: FileHeaderButtonId): void;
  leave(path: string): void;
  toggleCollapsed(path: string): void;
  press(path: string, button: FileHeaderButtonId): void;
}

/** Diff renderer options shared by every file. */
export interface DiffDisplay {
  wrap: boolean;
  split: boolean;
}

function FileHeader({
  file,
  view,
  anchor,
  on,
  onMounted,
}: {
  file: ChangedFile;
  view: FileView;
  anchor: (button: FileHeaderButtonId) => string;
  on: FileHandlers;
  onMounted: (el: HTMLElement | null) => void;
}) {
  const slash = file.path.lastIndexOf("/");
  const dir = slash >= 0 ? file.path.slice(0, slash + 1) : "";
  const base = file.path.slice(slash + 1);
  const lit = (id: FileHeaderButtonId) =>
    view.hoveredButton === id || (id === "actions" && view.menuOpen) || (id === "viewed" && view.viewed);
  return (
    <div
      className="cx-file-header"
      data-hovered={view.hovered ? "" : undefined}
      ref={onMounted}
      onPointerEnter={() => on.hover(file.path)}
      onPointerLeave={() => on.leave(file.path)}
    >
      <span className="cx-fh-icon">
        <FileTypeIcon path={file.path} />
      </span>
      <button
        type="button"
        className="cx-fh-name"

        aria-expanded={!view.collapsed}
        onClick={() => on.toggleCollapsed(file.path)}
      >
        {dir && <span className="cx-fh-dir">{dir}</span>}
        <span className="cx-fh-base">{base}</span>
      </button>
      {view.hovered && (
        <I.ChevronDown className="cx-fh-chevron" width={14} height={14} onClick={() => on.toggleCollapsed(file.path)} />
      )}
      <span className="cx-fh-spacer" />
      <Counts additions={file.additions} deletions={file.deletions} alwaysBoth />
      <span className="cx-fh-actions">
        {HEADER_BUTTONS.map((id) => (
          <span key={id} className="cx-fh-slot" data-id={id} {...anchorProps(anchor(id))}>
            <button
              type="button"
              className="cx-fh-btn"
              data-id={id}
              aria-label={HEADER_LABELS[id]}
              aria-pressed={id === "viewed" ? view.viewed : undefined}
              data-hover={lit(id) ? "" : undefined}
              onPointerEnter={() => on.hover(file.path, id)}
              onPointerLeave={() => on.hover(file.path)}
              onClick={() => on.press(file.path, id)}
            >
              {HEADER_ICONS[id]}
            </button>
          </span>
        ))}
      </span>
    </div>
  );
}

function FileDiffBlock({
  file,
  view,
  display,
  anchor,
  on,
  onPainted,
  onHeaderMounted,
}: {
  file: ChangedFile;
  view: FileView;
  display: DiffDisplay;
  anchor: (button: FileHeaderButtonId) => string;
  on: FileHandlers;
  onPainted: () => void;
  onHeaderMounted: (el: HTMLElement | null) => void;
}) {
  const wrap = useRef<HTMLDivElement>(null);
  const scrolled = useRef(false);
  const { thumb, attach } = useOverlayThumb("x", 2.5, 3.5);
  // Pierre calls onPostRender after each paint: hook the overlay scrollbar to the code
  // scroller inside its shadow root, apply the initial scroll once, then report the paint.
  const afterRender = useStableCallback(() => {
    const host = (wrap.current?.firstElementChild as HTMLElement | null) ?? null;
    const code = host?.shadowRoot?.querySelector<HTMLElement>("[data-code]") ?? null;
    if (code && view.scrollLeft !== undefined && !scrolled.current) {
      code.scrollLeft = view.scrollLeft;
      scrolled.current = true;
    }
    attach(code);
    onPainted();
  });
  const options = useMemo(
    () => ({
      theme: CODEX_DIFF_THEME,
      themeType: "dark" as const,
      diffStyle: display.split ? ("split" as const) : ("unified" as const),
      diffIndicators: "bars" as const,
      hunkSeparators: "line-info" as const,
      lineDiffType: "none" as const,
      overflow: display.wrap ? ("wrap" as const) : ("scroll" as const),
      // jsdiff defaults to 4 context lines; Codex shows 3.
      parseDiffOptions: { context: 3 },
      collapsed: view.collapsed,
      unsafeCSS: diffUnsafeCSS,
      onPostRender: afterRender,
    }),
    [view.collapsed, display.split, display.wrap, afterRender],
  );
  const oldFile = useMemo(
    () => ({
      name: file.previousPath ?? file.path,
      contents: file.oldContents ?? "",
      lang: file.lang as never,
    }),
    [file],
  );
  const newFile = useMemo(
    () => ({ name: file.path, contents: file.newContents ?? "", lang: file.lang as never }),
    [file],
  );
  const header = () => <FileHeader file={file} view={view} anchor={anchor} on={on} onMounted={onHeaderMounted} />;
  return (
    <div className="cx-file" ref={wrap} data-path={file.path} data-collapsed={view.collapsed ? "" : undefined}>
      {file.patch !== undefined ? (
        <PatchDiff className="cx-file-diff" patch={file.patch} options={options} renderCustomHeader={header} />
      ) : (
        <MultiFileDiff
          className="cx-file-diff"
          oldFile={oldFile}
          newFile={newFile}
          options={options}
          renderCustomHeader={header}
        />
      )}
      {file.note && !view.collapsed && <div className="cx-file-note">{file.note}</div>}
      {!view.collapsed && !display.wrap && (
        <div className="cx-hscroll">
          {thumb && <div className="cx-thumb" style={{ left: thumb.offset, width: thumb.length }} />}
        </div>
      )}
    </div>
  );
}

export function DiffList({
  files,
  fileView,
  display,
  anchor,
  on,
  onPainted,
  onHeaderMounted,
}: {
  files: readonly ChangedFile[];
  fileView: (path: string) => FileView;
  display: DiffDisplay;
  anchor: (index: number, button: FileHeaderButtonId) => string;
  on: FileHandlers;
  onPainted: (path: string) => void;
  onHeaderMounted: (path: string, el: HTMLElement | null) => void;
}) {
  return files.map((f, index) => (
    <FileDiffBlock
      key={f.path}
      file={f}
      view={fileView(f.path)}
      display={display}
      anchor={(button) => anchor(index, button)}
      on={on}
      onPainted={() => onPainted(f.path)}
      onHeaderMounted={(el) => onHeaderMounted(f.path, el)}
    />
  ));
}

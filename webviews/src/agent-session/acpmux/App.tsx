import React, { memo, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { QueryClientProvider } from "@tanstack/react-query";
import { applyAgentTheme } from "../shared/theme";
import {
  diffRows,
  layoutConversation,
  paneHeader,
  placeRows,
  plainEditLabels,
  transcriptRowWidth,
  visibleLayoutRange,
  type AcpmuxPermission,
  type AcpmuxRow,
  type AcpmuxSnapshot,
} from "./model";
import { AcpmuxDirectClient, type AcpmuxHostConfig } from "./direct";
import { postNative } from "./native";
import { pageHostClient, startHostEvents } from "./pageHost";
import { NewTabPage, newTabHost, type NewTabHost, type TabKind } from "./NewTabPage";
import { NewTabScreen } from "./newtab/NewTabScreen";
import { newTabScreenActions } from "./newtab/screenActions";
import { useNewTabAdoption } from "./newtab/adoption";
import { projectLabel } from "./sessionList";
import { composerDraft } from "./composerDraft";
import { paneContext } from "./paneContext";
import { createPaneQueryClient, useHarnessCatalog, type HarnessCatalogSource } from "./catalog";
import { MockAcpmuxSocket, mockHost, type MockScript } from "./mock";
import { useComposerKeyboard } from "./composerFocus";
import { createAcpmuxDebug, type AcpmuxDebug } from "./debug";
import { acpWire } from "./wire";
import { acpmuxPerf } from "./perf";
import { ScrollPacing } from "./pacing";
import { AdaptiveRenderRate, reportScrollPacing } from "./renderPacing";
import { Composer } from "./Composer";
import { ComposerPickers } from "./ComposerPickers";
import { EmptyState, isNewChat, projectName } from "./EmptyState";
import { HomeLists } from "./HomeLists";
import { SessionSidebar, type SidebarAccount } from "./SessionSidebar";
import { turnFiles, turnRows, undoPrompt, type TurnFile } from "./diff";
import type { TrustSource } from "./folderTrust";
import { TrustAsk } from "./TrustAsk";
import { PermissionCard } from "./PermissionCard";
import { agentName } from "./agents";
import { useT } from "./i18n";
import { useFolderTrustAsk } from "./useFolderTrustAsk";
import { FILE_SEARCH_LIMIT, type FileSearchSource } from "./fileSearchModel";
import { DiffPanel } from "./DiffPanel";
import { SummaryButton } from "./summary/SummaryButton";
import { turnCounts, turnDisplay } from "./changes/turnCheckpoint";
import { TurnCountsContext, type TurnCountsFor } from "./changes/TurnCountsContext";
import { useTurnCheckpoints } from "./changes/useTurnCheckpoints";
import { readTurnFromRows, type CheckpointDiff } from "./changes/turnCheckpointSource";
import {
  restoredDecisions,
  turnHunkKeys,
  undoableHunks,
  type HunkDecision,
  type HunkReview,
} from "./changes/hunkReview";
import { configureDictation, deliverDictation, useDictation } from "./dictation";
import type { DictationUpdate } from "./dictationText";
import { DictationButton } from "./DictationButton";
import { DictationNotice } from "./DictationNotice";
import type { MarkdownFieldHandle } from "./MarkdownField";
import type { ChangesSource } from "./changes/model";
import { Counts } from "./changes/Counts";
import { ChevronDown, DiffFile } from "./changeIcons";
import { RevealedMarkdown } from "./conversation/RevealedMarkdown";
import { ToolRows, TurnFooter, WorkedFor } from "./conversation/TurnRows";
import { TurnActionsContext, type TurnActions } from "./conversation/turnActions";
import { Undo } from "./conversation/icons";
import { DATE, PREVIEW, THINKING, WORKED, WORKING, isFoldedCopy, turnView } from "./conversation/turns";
import { PreviewCard } from "./conversation/PreviewCard";
import { DateLine } from "./conversation/DateLine";
import { SearchChats } from "./SearchChats";
import { ShortcutsContext, readShortcuts, type ShortcutLabels } from "./shortcuts";
import { FALLBACK_LINK_SCHEME, revealTurnWhenShown, setLinkScheme } from "./links";
import { CopyChatLink } from "./CopyChatLink";
import { Thinking } from "./conversation/Thinking";
import { WorkingFor } from "./conversation/WorkingFor";
import { HostError } from "./HostError";
import { ContinueMenu } from "./handoff/ContinueMenu";
import { HandoffReviewMessage } from "./handoff/ReviewMessage";
import { handoffStrings, localizedHandoffStrings } from "./handoff/strings";
import type { HandoffReviewInput } from "./handoff/review";
import { useCheckpoints } from "./checkpoints/controller";
import { PermissionPanel } from "./permissions/Panel";
import type { PermissionDecision } from "./permissions/protocol";
import { checkpointStrings, localizedCheckpointStrings } from "./checkpoints/strings";
import { QUICK_MESSAGES, readSurface, useEscapeToDismiss, type PaneSurface } from "./paneSurface";
import { QuickSurface } from "./QuickSurface";

type MeasurableRenderer = React.ComponentType<RowProps> & { measure?: (row: AcpmuxRow, width: number) => number };
type NativeRegistry = Record<string, MeasurableRenderer>;
/// `onOpenDiff` opens the changes of the turn holding `rowId`, at `path` when given; focus
/// returns to `opener` when the view closes.
type OpenDiff = (rowId: string, path?: string, opener?: HTMLElement) => void;
type RowProps = {
  row: AcpmuxRow;
  onToggleActivity: (id: string) => void;
  expanded: boolean;
  onOpenDiff?: OpenDiff;
};

declare global {
  interface Window {
    cmuxAcpmuxBridge?: {
      receive(snapshot: AcpmuxSnapshot): void;
      applyTheme(theme: Record<string, unknown>): void;
      applyCustomization(customization: {
        themeCSS?: string;
        registryJS?: string;
        layout?: Record<string, unknown>;
      }): void;
      /// An app action for the page (CmuxNextAgentPane AgentPaneView): "searchChats" toggles Search chats.
      command?(name: string): void;
      /// The app's shortcuts as the user bound them, keyed by action id (shortcuts.ts).
      applyShortcuts?(labels: Record<string, string>): void;
      /// Preview features on or off (Settings > Advanced > Labs, `labs.previewFeatures`, off by
      /// default): the session coverage label and the sidebar's Pull requests view.
      applyPreview?(on: boolean): void;
      /// Scrolls to a turn a `cmux://session/<id>#turn-<turnId>` link names (links.ts), once its row
      /// renders; gives up quietly after a few seconds.
      revealTurn?(turnId: string): void;
      /// A dictation change from the host (CmuxNextAgentPane AgentPaneDictation), spliced at the prompt's cursor.
      dictation?(update: DictationUpdate): void;
    };
    cmuxAcpmuxRegistry?: {
      register(
        kind: string,
        renderer: MeasurableRenderer,
        options?: { measure?: (row: AcpmuxRow, width: number) => number },
      ): void;
      configure(options: Record<string, unknown>): void;
    };
    cmuxAcpmuxDebug?: AcpmuxDebug;
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    /// Mock mode only: a recorded turn the in-page daemon replays (webviews/scripts/agent-pane).
    cmuxAcpmuxMockScript?: MockScript;
    React?: typeof React;
  }
}

/** Who mock mode is signed in as, for the sidebar's account row. */
const MOCK_ACCOUNT: SidebarAccount = { name: "Leo", detail: "Max" };

/** The host's `account`, kept only when its fields are strings. */
function hostAccount(value: unknown): SidebarAccount | undefined {
  const account = value as { name?: unknown; detail?: unknown } | undefined;
  if (typeof account?.name !== "string" || !account.name) return undefined;
  return { name: account.name, detail: typeof account.detail === "string" ? account.detail : undefined };
}

function emptySnapshot(): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "connecting",
    isWorking: false,
    queue: [],
    catalog: [],
    canLoadOlder: false,
  };
}

function cachedSnapshot(): AcpmuxSnapshot {
  try {
    const value = JSON.parse(sessionStorage.getItem("cmux.acpmux.snapshot") ?? "null");
    if (value?.type === "snapshot" && Array.isArray(value.rows) && Array.isArray(value.sessions)) {
      acpmuxPerf.markAgent("snapshotPaint");
      return { ...emptySnapshot(), ...value, connection: "connecting" };
    }
  } catch {
    // A corrupt or unavailable session store must never block the pane.
  }
  return emptySnapshot();
}

/// A page action: the connected client's (chat actions run against acpmux), else the native host.
function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  return postNative<T>(method, params);
}

/// Asks the host to show the Quick Composer's chat in a window.
const postOpenInWindow = (sessionId: string) =>
  void callNative(QUICK_MESSAGES.openInWindow, { sessionId }).catch(() => undefined);

/// Folder trust lives with acpmux (or the mock daemon), else the native host.
const trustSource: TrustSource = {
  get: (cwd) => callNative("acp.trust.get", { cwd }),
  set: (cwd, level) => callNative("acp.trust.set", { cwd, level }),
};

/// The changes view reads git scopes through the client, which knows the selected session's
/// folder and asks the native host (or, in mock mode, the in-page daemon).
const changesSource: ChangesSource = {
  diff: (scope) => callNative("git.diff", { scope, include_patch: true }),
  status: () => callNative("git.status", {}),
};
/// A turn's checkpoint pair, diffed on the session host (`git.checkpoint.diff`).
const checkpointDiff: CheckpointDiff = (from, to) =>
  callNative("git.checkpoint.diff", { from, to, include_patch: true });
/// The host opens a changed file in a tab beside the agent or in the editor (`file.open`).
const openChangedFile = (path: string, where: "tab" | "editor") => callNative("file.open", { path, where });

/// A prompt draws as the user typed it, in a bubble at the right; a reply as Markdown.
const MessageRow = memo(
  function MessageRow({ row }: RowProps) {
    if (row.kind === "user")
      return (
        <div className="cv-user">
          <div className="cv-user__bubble selectable">{row.text ?? ""}</div>
        </div>
      );
    return <RevealedMarkdown text={row.text ?? ""} streaming={row.streaming === true} />;
  },
  (previous, next) => previous.row.id === next.row.id && previous.row.version === next.row.version,
);

/// Tool calls and thoughts as quiet rows (inside an open "Worked for", or live).
const ToolActivityRow = memo(
  function ToolActivityRow({ row }: RowProps) {
    return <ToolRows row={row} />;
  },
  (previous, next) => previous.row.id === next.row.id && previous.row.version === next.row.version,
);

/// "Worked for 15s": opens the turn's commentary and tool calls (turnView in conversation/turns.ts).
const WorkedRow = memo(
  function WorkedRow({ row, onToggleActivity, expanded }: RowProps) {
    return <WorkedFor row={row} expanded={expanded} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.expanded === b.expanded &&
    a.onToggleActivity === b.onToggleActivity,
);

/// "Sun, Sep 13 at 7:55 PM" over a prompt after an hour's gap (turnView in conversation/turns.ts).
const DateRow = memo(
  function DateRow({ row }: RowProps) {
    return <DateLine row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.at === b.row.at,
);
/// A running turn's status: "Thinking", then "Working for 42s" (turnView in conversation/turns.ts).
const ThinkingRow = memo(
  function ThinkingRow(_: RowProps) {
    return <Thinking />;
  },
  (a, b) => a.row.id === b.row.id,
);
const WorkingRow = memo(
  function WorkingRow({ row }: RowProps) {
    return <WorkingFor row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.row.durationMs === b.row.durationMs,
);

/// Asks the host for a browser tab on a turn's local web page; a host without one (the quick
/// panel) refuses, and the card's address still opens outside the pane.
const openPreview = (url: string) => void callNative("browser.open", { url }).catch(() => undefined);
/// A turn's local web page, live (conversation/PreviewCard.tsx).
const PreviewRow = memo(
  function PreviewRow({ row }: RowProps) {
    return row.text ? <PreviewCard url={row.text} onOpen={openPreview} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.text === b.row.text,
);

const SummaryRow = memo(
  function SummaryRow({ row }: RowProps) {
    return <TurnFooter row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const NoticeRow = memo(
  function NoticeRow({ row }: RowProps) {
    return <div className="acpmux-muted">{row.text}</div>;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const PermissionRow = memo(
  function PermissionRow({ row }: RowProps) {
    const t = useT();
    const permission = row.permission;
    if (!permission)
      return (
        <div className="acpmux-permission-card">
          <strong>{t("permission.required")}</strong>
        </div>
      );
    return <PermissionCard permission={permission} onAnswer={answerPermission(permission)} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const EDITED_FILES_SHOWN = 3;

/// "Edited N files", ported from EditedFilesCard in the reference prototype's
/// src/conversation/cards.tsx): totals, View changes, and the first files with their counts;
/// each file opens the changes at that file. One edited file is named in the title instead.
const EditedFilesRow = memo(
  function EditedFilesRow({ row, onOpenDiff }: RowProps) {
    const t = useT();
    const [showAll, setShowAll] = useState(false);
    const edits = (row.items ?? []).filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange");
    const toolFiles = useMemo(() => turnFiles([row]), [row]);
    // Once the turn's checkpoint has loaded, its files and counts replace the tool calls'.
    const countsFor = useContext(TurnCountsContext);
    const counts = useMemo(
      () => (countsFor ? countsFor(row.id, toolFiles) : turnCounts(toolFiles, undefined)),
      [countsFor, row.id, toolFiles],
    );
    const files = counts.files;
    // An edit whose tool call carried no diff still lists, without counts.
    const plain = counts.files === toolFiles ? plainEditLabels(edits) : [];
    const entries: { key: string; file?: TurnFile; text?: string }[] = [
      ...files.map((file) => ({ key: file.path, file })),
      ...plain.map((text, index) => ({ key: `plain-${index}`, text })),
    ];
    const total = entries.length;
    const { additions, deletions } = counts;
    const single = total === 1 && files.length === 1 ? files[0] : undefined;
    const shown = single ? [] : showAll ? entries : entries.slice(0, EDITED_FILES_SHOWN);
    const more = single ? 0 : total - shown.length;
    const reviewable = onOpenDiff && files.length > 0;
    const { review } = useContext(TurnActionsContext);
    const unasked =
      review && row.ended && toolFiles.length > 0
        ? turnHunkKeys(toolFiles).filter((key) => review.decisions.get(key) !== "requested").length
        : undefined;
    return (
      <div className="acpmux-edited">
        <div className="acpmux-edited-head">
          <span className="acpmux-edited-icon">
            <DiffFile />
          </span>
          <div className="acpmux-edited-title">
            <div>
              {single ? `Edited ${single.path.split("/").pop()}` : `Edited ${total} ${total === 1 ? "file" : "files"}`}
            </div>
            {files.length > 0 && <Counts additions={additions} deletions={deletions} />}
            {counts.outside && <span className="acpmux-edited-outside">{t("turn.outside.card")}</span>}
          </div>
          {review && unasked !== undefined && (
            <button
              type="button"
              className="acpmux-edited-undo"
              disabled={unasked === 0}
              title={unasked ? t("edited.undoLabel") : undefined}
              onClick={() => {
                const hunks = undoableHunks(toolFiles, review.decisions);
                review.requestRevert(
                  hunks.map((hunk) => hunk.key),
                  undoPrompt(hunks.map((hunk) => hunk.patch)),
                );
              }}
            >
              {unasked ? t("edited.undo") : t("edited.undoRequested")}
              {unasked > 0 && <Undo size={14} />}
            </button>
          )}
          {reviewable && (
            <button
              type="button"
              className="acpmux-review-changes"
              onClick={(event) => onOpenDiff(row.id, single?.path, event.currentTarget)}
            >
              View changes
            </button>
          )}
        </div>
        {shown.map((entry) => {
          if (!entry.file)
            return (
              <div className="acpmux-edited-file" key={entry.key}>
                <span className="acpmux-edited-path">{entry.text}</span>
              </div>
            );
          const file = entry.file;
          const slash = file.displayPath.lastIndexOf("/");
          const label = (
            <>
              <span className="acpmux-edited-path" title={file.path}>
                <span className="acpmux-edited-dir">{file.displayPath.slice(0, slash + 1)}</span>
                <span className="acpmux-edited-base">{file.displayPath.slice(slash + 1)}</span>
              </span>
              <Counts additions={file.additions} deletions={file.deletions} />
            </>
          );
          return onOpenDiff ? (
            <button
              type="button"
              className="acpmux-edited-file"
              key={entry.key}
              onClick={(event) => onOpenDiff(row.id, file.path, event.currentTarget)}
            >
              {label}
            </button>
          ) : (
            <div className="acpmux-edited-file" key={entry.key}>
              {label}
            </div>
          );
        })}
        {(more > 0 || showAll) && !single && total > EDITED_FILES_SHOWN && (
          <button
            type="button"
            className="acpmux-edited-more"
            aria-expanded={showAll}
            onClick={() => setShowAll(!showAll)}
          >
            {showAll ? "Show fewer files" : `Show ${more} more ${more === 1 ? "file" : "files"}`}
            <ChevronDown width={14} height={14} style={showAll ? { transform: "rotate(180deg)" } : undefined} />
          </button>
        )}
      </div>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.onOpenDiff === b.onOpenDiff,
);

const defaultRegistry: NativeRegistry = {
  user: MessageRow,
  assistant: MessageRow,
  activity: ToolActivityRow,
  [WORKED]: WorkedRow,
  [DATE]: DateRow,
  [THINKING]: ThinkingRow,
  [WORKING]: WorkingRow,
  [PREVIEW]: PreviewRow,
  editedFiles: EditedFilesRow,
  turnSummary: SummaryRow,
  notice: NoticeRow,
  plan: NoticeRow,
  typing: NoticeRow,
  permission: PermissionRow,
};

/// A row's height as the page drew it, valid while the row's content version and width hold.
type DrawnHeight = { version: number; width: number; height: number };
type ReportDrawn = (id: string, version: number, height: number) => void;

/// Slides the thread from `step` px below to its place over 180 ms, so content that grew at the
/// latest row glides in. Glides stack (`composite: "add"`). None under Reduce Motion.
function glide(node: HTMLElement | null, step: number): void {
  if (!node || typeof node.animate !== "function") return;
  if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;
  node.animate([{ transform: `translateY(${step}px)` }, { transform: "translateY(0px)" }], {
    duration: GLIDE_MS,
    easing: "cubic-bezier(0.2, 0, 0, 1)",
    composite: "add",
  });
}
const GLIDE_MS = 180;

/// Whether `updates` change any drawn height in `current`.
function changesDrawn(current: Map<string, DrawnHeight>, updates: Map<string, DrawnHeight>): boolean {
  for (const [id, entry] of updates) {
    const old = current.get(id);
    if (
      !old ||
      old.version !== entry.version ||
      old.width !== entry.width ||
      Math.abs(old.height - entry.height) >= 0.5
    )
      return true;
  }
  return false;
}

/// One transcript row. It reports its drawn height before the frame paints whenever it mounts or
/// its content, width or expansion changes; the transcript's ResizeObserver reports later changes
/// (a font that loads, a custom renderer that grows).
function RowFrame({
  row,
  kind,
  index,
  setSize,
  top,
  rowWidth,
  expanded,
  observer,
  report,
  enter,
  onEntered,
  children,
}: {
  row: AcpmuxRow;
  kind: string;
  index: number;
  setSize: number;
  top: number;
  rowWidth: number;
  expanded: boolean;
  observer: ResizeObserver | undefined;
  report: ReportDrawn;
  /// The row arrived live: it enters with the shared motion on this, its first mount.
  enter: boolean;
  onEntered: (id: string) => void;
  children: React.ReactNode;
}) {
  const ref = useRef<HTMLElement>(null);
  const [entering] = useState(enter);
  useLayoutEffect(() => {
    if (entering) onEntered(row.id);
    // Only the first mount enters.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || !observer) return;
    observer.observe(node);
    return () => observer.unobserve(node);
  }, [observer]);
  useLayoutEffect(() => {
    const node = ref.current;
    if (node) report(row.id, row.version, node.getBoundingClientRect().height);
  }, [row.id, row.version, rowWidth, expanded, report]);
  return (
    <article
      ref={ref}
      data-row-id={row.id}
      className={`acpmux-row acpmux-${kind}${entering ? " acpmux-row--enter" : ""}`}
      aria-label={speaker(kind)}
      aria-posinset={index + 1}
      aria-setsize={setSize}
      style={{ transform: `translateY(${top}px)` }}
    >
      {children}
    </article>
  );
}

/// Who spoke, for assistive technology: each article is one message in the transcript feed.
const speaker = (kind: string) => (kind === "user" ? "You" : kind === "assistant" ? "Agent" : undefined);
const rowKind = (row: AcpmuxRow) =>
  row.kind === "activity" &&
  !isFoldedCopy(row) &&
  row.items?.some((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange")
    ? "editedFiles"
    : row.kind;
const currentRegistry = (): NativeRegistry => ({
  ...defaultRegistry,
  ...(window.cmuxAcpmuxRegistry as unknown as NativeRegistry | undefined),
});

/// Where a scroller sits, read while its content still matches `totalHeight`.
const scrollPosition = (node: HTMLElement, totalHeight: number) => ({
  top: node.scrollTop,
  atLatest: node.scrollTop >= totalHeight - node.clientHeight - 1,
});

/// Scroll steps of rows mounted ahead in the scroll direction, capped in viewports.
/// A scroll commits from its event, a frame after the offset moved, so without the
/// lead a fling shows a blank edge on every frame.
const SCROLL_LEAD_STEPS = 2;
/// More new rows than this in one update are a load (a session switch, older history), not live rows.
const LIVE_ROWS_PER_UPDATE = 3;
const MAX_SCROLL_LEAD_VIEWPORTS = 4;

export function VirtualTranscript({
  rows,
  onToggleActivity,
  onOpenDiff,
  expanded,
  registry = defaultRegistry,
  canLoadOlder = false,
}: {
  rows: AcpmuxRow[];
  onToggleActivity: (id: string) => void;
  onOpenDiff?: OpenDiff;
  expanded: Set<string>;
  registry?: NativeRegistry;
  canLoadOlder?: boolean;
}) {
  // Debug measurement (acpmuxPerf): off until the first debug call.
  const renderStart = acpmuxPerf.enabled ? performance.now() : 0;
  const [scroll, setScroll] = useState({ top: 0, delta: 0 });
  const [height, setHeight] = useState(600);
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(760);
  // Rows place by their drawn height once drawn, and by the estimate until then.
  const [drawn, setDrawn] = useState(new Map<string, DrawnHeight>());
  const pendingDrawn = useRef(new Map<string, DrawnHeight>());
  const drawnRef = useRef(drawn);
  drawnRef.current = drawn;
  const rowWidthRef = useRef(transcriptRowWidth(width));
  rowWidthRef.current = transcriptRowWidth(width);
  const rowsRef = useRef(rows);
  rowsRef.current = rows;
  // Rows that arrive live (a reply, a tool call, a status line) enter once. The rows at the first
  // render, and many at once (a session switch, older history), are a load and do not.
  const knownRows = useRef<Set<string> | null>(null);
  const enteringRows = useRef(new Set<string>());
  if (knownRows.current === null) knownRows.current = new Set(rows.map((row) => row.id));
  else {
    const arrived = rows.filter((row) => !knownRows.current!.has(row.id));
    for (const row of arrived) knownRows.current.add(row.id);
    if (arrived.length <= LIVE_ROWS_PER_UPDATE) for (const row of arrived) enteringRows.current.add(row.id);
  }
  const onEntered = useCallback((id: string) => void enteringRows.current.delete(id), []);
  const reportDrawn = useCallback<ReportDrawn>((id, version, drawnHeight) => {
    // Zero is a row not laid out (hidden, or no layout at all), not a height.
    if (drawnHeight > 0) pendingDrawn.current.set(id, { version, width: rowWidthRef.current, height: drawnHeight });
  }, []);
  // All of a commit's reports land in one update, before the frame paints.
  const flushDrawn = useCallback(() => {
    if (!pendingDrawn.current.size) return;
    const updates = pendingDrawn.current;
    pendingDrawn.current = new Map();
    setDrawn((current) => {
      let next: Map<string, DrawnHeight> | undefined;
      for (const [id, entry] of updates) {
        const old = current.get(id);
        if (
          old &&
          old.version === entry.version &&
          old.width === entry.width &&
          Math.abs(old.height - entry.height) < 0.5
        )
          continue;
        next ??= new Map(current);
        next.set(id, entry);
      }
      return next ?? current;
    });
  }, []);
  const observer = useMemo(
    () =>
      typeof ResizeObserver === "undefined"
        ? undefined
        : new ResizeObserver((entries?: ResizeObserverEntry[]) => {
            for (const entry of entries ?? []) {
              const target = entry.target as HTMLElement;
              const row = rowsRef.current[Number(target.getAttribute("aria-posinset")) - 1];
              if (row && row.id === target.dataset.rowId)
                reportDrawn(row.id, row.version, target.getBoundingClientRect().height);
            }
            // A late size change (a font loading) must not paint a frame of overlap first. Sizes
            // that did not change render nothing: a synchronous render here for nothing was the
            // "ResizeObserver loop completed with undelivered notifications" while streaming.
            if (!changesDrawn(drawnRef.current, pendingDrawn.current)) pendingDrawn.current = new Map();
            else flushSync(flushDrawn);
          }),
    [reportDrawn, flushDrawn],
  );
  useEffect(() => () => observer?.disconnect(), [observer]);
  // Forget rows that left the transcript (a session switch, older history unloaded).
  useEffect(() => {
    const cache = measurementCache.current;
    if (cache.size <= rows.length && drawn.size <= rows.length) return;
    const ids = new Set(rows.map((row) => row.id));
    for (const id of cache.keys()) if (!ids.has(id)) cache.delete(id);
    setDrawn((current) => {
      if ([...current.keys()].every((id) => ids.has(id))) return current;
      return new Map([...current].filter(([id]) => ids.has(id)));
    });
  }, [rows, drawn]);
  useLayoutEffect(flushDrawn);
  const didOpenAtLatest = useRef(false);
  const measurementCache = useRef(new Map<string, import("./model").PreparedRow>());
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const observer = new ResizeObserver(() => {
      setHeight(node.clientHeight);
      setWidth(node.clientWidth);
    });
    observer.observe(node);
    setWidth(node.clientWidth);
    return () => observer.disconnect();
  }, []);
  const previousLayout = useRef<ReturnType<typeof layoutConversation> | null>(null);
  const previousRows = useRef<AcpmuxRow[]>(rows);
  const thread = useRef<HTMLDivElement>(null);
  // The reader scrolls: a glide in flight ends at once, so the view goes where they scroll.
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const endGlide = () => {
      for (const animation of thread.current?.getAnimations?.() ?? []) animation.finish();
    };
    const events = ["wheel", "touchstart", "keydown"] as const;
    for (const name of events) node.addEventListener(name, endGlide, { passive: true });
    return () => {
      for (const name of events) node.removeEventListener(name, endGlide);
    };
  }, []);
  const scrolledTo = useRef({ top: 0, atLatest: false });
  // Scroll frames re-render with the same rows; only rows, width or the registry
  // change an estimate.
  const estimated = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    const layout = layoutConversation(rows, transcriptRowWidth(width), measurementCache.current, (row, rowWidth) =>
      registry[rowKind(row)]?.measure?.(row, rowWidth),
    );
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
  }, [rows, width, registry]);
  // A row that draws moves only the rows below it: place them again, measuring none.
  const measured = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    const rowWidth = transcriptRowWidth(width);
    const layout =
      drawn.size === 0
        ? estimated.layout
        : placeRows(estimated.layout, (index) => {
            const known = drawn.get(rows[index].id);
            return known && known.version === rows[index].version && known.width === rowWidth
              ? known.height
              : undefined;
          });
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
  }, [estimated, drawn, rows, width]);
  const layout = measured.layout;
  const reportedLayout = useRef<typeof measured | null>(null);
  const reportedEstimate = useRef<typeof estimated | null>(null);
  const lead = Math.min(Math.abs(scroll.delta) * SCROLL_LEAD_STEPS, height * MAX_SCROLL_LEAD_VIEWPORTS);
  const range = visibleLayoutRange(layout, scroll.delta < 0 ? scroll.top - lead : scroll.top, height + lead);
  useLayoutEffect(() => {
    const last = range.last - 1;
    acpmuxPerf.mountedTop = range.last > range.first ? layout.tops[range.first] : 0;
    acpmuxPerf.mountedBottom = range.last > range.first ? layout.tops[last] + layout.heights[last] : 0;
    // A memo hit spent no time in geometry this render.
    const freshLayout = reportedLayout.current !== measured;
    reportedLayout.current = measured;
    const freshEstimate = reportedEstimate.current !== estimated;
    reportedEstimate.current = estimated;
    const layoutMs = (freshLayout ? measured.ms : 0) + (freshEstimate ? estimated.ms : 0);
    if (acpmuxPerf.enabled && freshLayout) acpmuxPerf.addLayout(layoutMs);
    if (acpmuxPerf.enabled && renderStart > 0) {
      const now = performance.now();
      acpmuxPerf.commit(now - renderStart, layoutMs, acpmuxPerf.mountedTop, acpmuxPerf.mountedBottom, now);
    }
  });
  useLayoutEffect(() => {
    const old = previousLayout.current;
    const oldRows = previousRows.current;
    const node = ref.current;
    if (old && node) {
      // Content that shrank under the viewport has already clamped the live offset to
      // the new end; the offset recorded before this commit is where the reader was.
      // A clamp lands exactly on the scroller's own end, which rounds the layout's
      // fractional height, so compare with that rather than allow for the rounding.
      const live = node.scrollTop;
      const clamped = live < scrolledTo.current.top - 0.5 && live >= node.scrollHeight - node.clientHeight - 0.5;
      // An offset that has not moved since it was recorded was at the latest row if it was
      // then; a shorter viewport alone would otherwise read as scrolled up.
      const unmoved = Math.abs(live - scrolledTo.current.top) <= 0.5;
      const top = clamped ? scrolledTo.current.top : live;
      const atLatest =
        clamped || unmoved ? scrolledTo.current.atLatest : top >= old.totalHeight - node.clientHeight - 1;
      // At the first row nothing above can move it.
      if (top > 0 && didOpenAtLatest.current && atLatest) {
        // At the latest row: stay there as rows settle to their drawn heights.
        const latest = Math.max(0, layout.totalHeight - node.clientHeight);
        const step = latest - node.scrollTop;
        if (Math.abs(step) > 0.5) node.scrollTop = latest;
        // Growth glides in instead of stepping a line per frame (acp-streaming.md "Scroll").
        if (step > 0.5 && step < node.clientHeight) glide(thread.current, step);
      } else if (top > 0) {
        // Keep the row at the top of the viewport where it is as rows above it change height.
        // Rows that arrived or left (a new reply segment below, older history above) move indexes,
        // so the row is found again by its id.
        const anchor = visibleLayoutRange(old, top, 0, 0).first;
        const id = oldRows[anchor]?.id;
        const now = rows[anchor]?.id === id ? anchor : rows.findIndex((row) => row.id === id);
        if (now >= 0) {
          const delta = layout.tops[now] - old.tops[anchor];
          if (clamped || Math.abs(delta) > 0.5) node.scrollTop = top + delta;
        }
      }
    }
    // Runs on height too: rows that fit and then overflow on a height-only shrink keep the same memoized layout.
    if (!didOpenAtLatest.current && node && layout.totalHeight > node.clientHeight) {
      const latest = Math.max(0, layout.totalHeight - node.clientHeight);
      node.scrollTop = latest;
      setScroll({ top: latest, delta: 0 });
      didOpenAtLatest.current = true;
    }
    previousLayout.current = layout;
    previousRows.current = rows;
    if (node) scrolledTo.current = scrollPosition(node, layout.totalHeight);
  }, [layout, rows, range.first, height]);
  // Commit before this frame paints; deferring to the next animation frame left the edge blank.
  // The page picks adaptive rendering; the host supplies the display interval and applies it.
  const renderRate = useMemo(() => new AdaptiveRenderRate(), []);
  const pacing = useMemo(
    () => new ScrollPacing((intervals) => void reportScrollPacing(intervals, callNative, renderRate)),
    [renderRate],
  );
  useEffect(() => () => pacing.stop(), [pacing]);
  const onScroll = (event: React.UIEvent<HTMLDivElement>) => {
    pacing.scrolled();
    const next = event.currentTarget.scrollTop;
    scrolledTo.current = scrollPosition(event.currentTarget, layout.totalHeight);
    flushSync(() => setScroll((current) => ({ top: next, delta: next - current.top })));
  };
  return (
    <div ref={ref} className="acpmux-scroll" role="feed" aria-label="Transcript" onScroll={onScroll}>
      <div className="acpmux-spacer" style={{ height: layout.totalHeight }}>
        <div ref={thread} className="acpmux-thread">
          {rows.slice(range.first, range.last).map((row, index) => {
            const absoluteIndex = range.first + index;
            const kind = rowKind(row);
            const Component = registry[kind] ?? NoticeRow;
            const isExpanded = expanded.has(row.id);
            return (
              <RowFrame
                key={row.id}
                row={row}
                kind={kind}
                index={absoluteIndex}
                setSize={canLoadOlder ? -1 : rows.length}
                top={layout.tops[absoluteIndex]}
                rowWidth={transcriptRowWidth(width)}
                expanded={isExpanded}
                observer={observer}
                report={reportDrawn}
                enter={enteringRows.current.has(row.id)}
                onEntered={onEntered}
              >
                <Component
                  row={row}
                  onToggleActivity={onToggleActivity}
                  onOpenDiff={onOpenDiff}
                  expanded={isExpanded}
                />
              </RowFrame>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/// Answers `permission` with the option a button or key picked.
const answerPermission = (permission: AcpmuxPermission) => (optionId: string) =>
  void callNative("chat.permission", { permissionId: permission.permissionId, optionId });

function DefaultComposerChips({ snapshot }: { snapshot: AcpmuxSnapshot }) {
  return (
    <ComposerPickers
      snapshot={snapshot}
      onModel={(modelId) => void callNative("chat.model", { modelId })}
      onMode={(modeId) => void callNative("chat.mode", { modeId })}
      onEffort={(configId, value) => void callNative("chat.effort", { configId, value })}
      onHarness={(harness) => void callNative("chat.new", { harness })}
    />
  );
}

/** Whether the pane is wide enough to show the session list beside the transcript. */
const WIDE_PANE = "(min-width: 640px)";
function wideSidebar(): boolean {
  return window.matchMedia?.(WIDE_PANE).matches ?? true;
}

export function AcpmuxApp() {
  const [queryClient] = useState(createPaneQueryClient);
  return (
    <QueryClientProvider client={queryClient}>
      <AcpmuxPane />
    </QueryClientProvider>
  );
}

function AcpmuxPane() {
  const t = useT();
  /// What a chat opened from another tab inherited (#16620); the composer starts with it.
  const [draft, setDraft] = useState<string | undefined>();
  const [snapshot, setSnapshot] = useState<AcpmuxSnapshot>(cachedSnapshot);
  const [handoffLabels, setHandoffLabels] = useState(handoffStrings);
  const [checkpointLabels, setCheckpointLabels] = useState(checkpointStrings);
  const [checkpointVariant, setCheckpointVariant] = useState<"compact" | "expanded">("compact");
  const checkpoints = useCheckpoints({
    request: callNative,
    target: snapshot.summary?.cwd
      ? { cwd: snapshot.summary.cwd, sessionId: snapshot.sessionId, hostKind: snapshot.summary.hostKind }
      : undefined,
    online: snapshot.connection === "connected",
    strings: checkpointLabels,
    variant: checkpointVariant,
  });
  const showCheckpoint = useRef(checkpoints.show);
  showCheckpoint.current = checkpoints.show;
  useEffect(() => {
    void callNative("pane.checkpointAvailability", { available: checkpoints.supported }).catch(() => undefined);
  }, [checkpoints.supported, snapshot.sessionId]);
  const [continuing, setContinuing] = useState(false);
  const [reviewReload, setReviewReload] = useState(0);
  useEffect(() => setContinuing(false), [snapshot.sessionId]);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  // Footer actions show only while acpmux is reachable. The client reports failures in the
  // transcript; a bridge that cannot route an action has nothing to add.
  const connected = snapshot.connection !== "disconnected" && !snapshot.connection.startsWith("connecting");
  const forkable = Boolean(snapshot.canFork) && connected;
  // A new chat centers its composer under the hero.
  const handoff = snapshot.handoff?.record;
  const reviewing =
    !!handoff &&
    handoff.target.sessionId === snapshot.sessionId &&
    ["draft", "starting"].includes(handoff.state) &&
    !snapshot.handoff?.receipt;
  const handoffLoading = !!snapshot.sessionId && !!snapshot.canHandoff && !snapshot.handoff?.ready;
  const freshChat = !reviewing && !handoffLoading && isNewChat(snapshot);
  // A folder the user hasn't decided on is asked about beside the chat's other permission asks,
  // once its first prompt went; nothing waits on the answer.
  const trustAsk = useFolderTrustAsk(trustSource, {
    sessionId: snapshot.sessionId,
    cwd: snapshot.summary?.cwd,
    started: !freshChat && snapshot.rows.length > 0,
    prompts: snapshot.rows.filter((row) => row.kind === "user").length,
  });
  const individualPermission =
    snapshot.permission?.pending && !(snapshot.permissionGroups?.supported && snapshot.permission.groupId)
      ? snapshot.permission
      : undefined;
  // Search files reads the session's folder through whoever runs the session: the acpmux
  // client (or the mock daemon), else the native host.
  const fileRoot = snapshot.summary?.cwd;
  const searchFiles = useCallback<FileSearchSource>(
    (query) => callNative("file.search", { ...(fileRoot ? { path: fileRoot } : {}), query, limit: FILE_SEARCH_LIMIT }),
    [fileRoot],
  );
  // Turn shape: work folds under "Worked for" until opened.
  const transcriptRows = useMemo(() => {
    const groups = snapshot.permissionGroups;
    const groupedIds = new Set(groups?.groups.flatMap((group) => group.items.map((item) => item.permissionId)));
    const rows = groups?.supported
      ? snapshot.rows.filter(
          (row) =>
            row.kind !== "permission" ||
            (!row.permission?.groupId && !groupedIds.has(row.permission?.permissionId ?? "")),
        )
      : snapshot.rows;
    return turnView(rows, expanded, { working: snapshot.isWorking });
  }, [snapshot.rows, expanded, snapshot.isWorking, snapshot.permissionGroups]);
  // The open changes view: a turn of one session, and the control that opened it.
  const [diffView, setDiffView] = useState<{
    sessionId?: string;
    rowId: string;
    path?: string;
    opener?: HTMLElement;
  }>();
  const sessionIdRef = useRef(snapshot.sessionId);
  sessionIdRef.current = snapshot.sessionId;
  // A click does not focus a button in WebKit, so the clicked control is the opener, not the focus.
  const openDiff = useCallback<OpenDiff>(
    (rowId, path, opener) =>
      setDiffView({
        sessionId: sessionIdRef.current,
        rowId,
        path,
        opener: opener ?? (document.activeElement instanceof HTMLElement ? document.activeElement : undefined),
      }),
    [],
  );
  // An output in the summary opens the changes of the last turn that wrote it, at that file.
  const openOutput = useCallback(
    (path: string) => {
      const row = [...snapshot.rows]
        .reverse()
        .find(
          (candidate) =>
            candidate.kind === "activity" &&
            candidate.items?.some((item) => item.tool?.diffs?.some((change) => change.path === path)),
        );
      if (row) openDiff(row.id, path);
    },
    [snapshot.rows, openDiff],
  );
  const closedByUser = useRef(false);
  const closeDiff = useCallback(() => {
    closedByUser.current = true;
    setDiffView(undefined);
  }, []);
  // Focus returns to the opener once the view is gone: until then the transcript is hidden,
  // and a hidden control can't take focus.
  const diffOpener = useRef<HTMLElement | undefined>(undefined);
  if (diffView?.opener) diffOpener.current = diffView.opener;
  useLayoutEffect(() => {
    if (diffView || !diffOpener.current) return;
    // A view that closed itself (session switch, turn gone) leaves focus where the reader put it.
    const focus = document.activeElement;
    if (closedByUser.current || !focus || focus === document.body) diffOpener.current.focus();
    closedByUser.current = false;
    diffOpener.current = undefined;
  }, [diffView]);
  // Row ids repeat across sessions (they count events), so another session closes the view.
  const diffOpen =
    diffView !== undefined &&
    diffView.sessionId === snapshot.sessionId &&
    snapshot.rows.some((row) => row.id === diffView.rowId);
  useEffect(() => {
    if (diffView && !diffOpen) setDiffView(undefined);
  }, [diffView, diffOpen]);
  // Hunk decisions outlive the view, so reopening a turn shows what was already decided.
  const [hunkDecisions, setHunkDecisions] = useState<ReadonlyMap<string, HunkDecision>>(() => new Map());
  const hunkReview = useMemo<HunkReview>(() => {
    const mark = (keys: string[], decision: HunkDecision, only?: HunkDecision) =>
      setHunkDecisions((current) => {
        const next = new Map(current);
        for (const key of keys) if (!only || next.get(key) === only) next.set(key, decision);
        return next;
      });
    return {
      decisions: hunkDecisions,
      decide: (key, decision) =>
        setHunkDecisions((current) => {
          const next = new Map(current);
          if (decision) next.set(key, decision);
          else next.delete(key);
          return next;
        }),
      requestRevert: (keys, prompt) => {
        const previous = keys.map((key) => [key, hunkDecisions.get(key)] as const);
        mark(keys, "requested");
        callNative("chat.send", { text: prompt }).catch(() =>
          setHunkDecisions((current) => restoredDecisions(current, previous)),
        );
      },
    };
  }, [hunkDecisions]);
  // Tool call ids belong to one session.
  useEffect(() => setHunkDecisions((current) => (current.size ? new Map() : current)), [snapshot.sessionId]);
  // Retry sends the turn's prompt as the composer would; a failed send shows in the transcript.
  const turnActions = useMemo<TurnActions>(
    () => ({
      ...(forkable && {
        fork: (throughSeq: number) => void callNative("chat.fork", { throughSeq }).catch(() => undefined),
      }),
      ...(connected && {
        retry: (prompt: string) => void callNative("chat.send", { text: prompt }).catch(() => undefined),
      }),
      review: hunkReview,
    }),
    [forkable, connected, hunkReview],
  );
  // Streaming text changes rows on every chunk; only the turn's tool calls change its files.
  const diffActivity = useRef<{ key: string; files: ReturnType<typeof turnFiles> }>(undefined);
  const diffFiles = useMemo(() => {
    if (!diffView || !diffOpen) return undefined;
    const activity = turnRows(snapshot.rows, diffView.rowId).filter((row) => row.kind === "activity");
    const key = `${diffView.rowId}\u0000${activity.map((row) => `${row.id}:${row.version}`).join("|")}`;
    if (diffActivity.current?.key !== key) diffActivity.current = { key, files: turnFiles(activity) };
    return diffActivity.current.files;
  }, [diffView, diffOpen, snapshot.rows]);
  // Each turn's checkpoint pair, named by the row that starts the turn: the checkpoints acpmux
  // recorded on its summary, diffed on the session host.
  const turnRowsRef = useRef(snapshot.rows);
  turnRowsRef.current = snapshot.rows;
  const readTurn = useCallback(
    ({ rowId }: { rowId: string }) => readTurnFromRows(turnRowsRef.current, rowId, checkpointDiff),
    [],
  );
  const turnCheckpoints = useTurnCheckpoints(readTurn, snapshot.sessionId);
  const { request: requestTurnCheckpoint, get: turnCheckpoint } = turnCheckpoints;
  const turnKey = useCallback((rowId: string) => turnRows(turnRowsRef.current, rowId)[0]?.id ?? rowId, []);
  const diffTurn = diffView && diffOpen ? turnKey(diffView.rowId) : undefined;
  // A turn's pair exists once it has ended, so the view asks then (and again when it ends while
  // the view is open); until then it shows the tool calls' edits.
  const diffTurnEnded =
    diffView && diffOpen ? turnRows(snapshot.rows, diffView.rowId).some((row) => row.kind === "turnSummary") : false;
  useEffect(() => {
    if (diffTurn && diffTurnEnded) requestTurnCheckpoint(diffTurn);
  }, [diffTurn, diffTurnEnded, requestTurnCheckpoint]);
  const diffDisplay = useMemo(() => {
    if (!diffFiles || !diffTurn) return undefined;
    // An Undo chosen but not yet sent holds the tool-call view; Keep has nothing to send.
    const toolIds = new Set(diffFiles.flatMap((file) => file.edits.map((edit) => edit.toolId)));
    const pending = [...hunkDecisions].some(
      ([key, decision]) => decision === "rejected" && toolIds.has(key.split("\u0000")[0]!),
    );
    return turnDisplay(t, diffFiles, turnCheckpoint(diffTurn) ?? { state: "loading" }, pending);
  }, [diffFiles, diffTurn, hunkDecisions, t, turnCheckpoint]);
  // The latest edited-files card shows its turn's checkpoint counts once the turn has ended.
  const endedEditTurn = useMemo(() => {
    let ended = false;
    for (let index = snapshot.rows.length - 1; index >= 0; index--) {
      const row = snapshot.rows[index]!;
      if (row.kind === "turnSummary") ended = true;
      else if (row.kind === "editedFiles") return ended ? row.id : undefined;
    }
    return undefined;
  }, [snapshot.rows]);
  useEffect(() => {
    if (endedEditTurn) requestTurnCheckpoint(turnKey(endedEditTurn));
  }, [endedEditTurn, requestTurnCheckpoint, turnKey]);
  const turnCountsFor = useCallback<TurnCountsFor>(
    (rowId, toolFiles) => turnCounts(toolFiles, turnCheckpoint(turnKey(rowId))),
    [turnCheckpoint, turnKey],
  );
  const [registry, setRegistry] = useState<NativeRegistry>(defaultRegistry);
  /// Who is signed in, when the host says: the sidebar's account row.
  const [account, setAccount] = useState<SidebarAccount>();
  /// The session list shows beside the transcript in a wide pane and on demand in a narrow one.
  const [sidebar, setSidebar] = useState<"auto" | "open" | "closed">("auto");
  const [newTab, setNewTab] = useState<NewTabHost | undefined>();
  // A prewarmed spare page gets its real context when Cmd-T adopts it; the generation remounts the screen.
  const newTabGeneration = useNewTabAdoption(setNewTab);
  const sidebarToggle = useRef<HTMLButtonElement>(null);
  // Escape and the scrim close the narrow-pane overlay and give focus back to its toggle.
  const closeOverlay = useCallback(() => {
    setSidebar("auto");
    sidebarToggle.current?.focus();
  }, []);
  // Crossing the width threshold resets the list to the default for the new width, so a list opened beside the transcript never turns into an overlay.
  const [wide, setWide] = useState(wideSidebar);
  useEffect(() => {
    const query = window.matchMedia?.(WIDE_PANE);
    if (!query?.addEventListener) return;
    // The width may have crossed the threshold between the first render and this subscription.
    setWide(query.matches);
    const onChange = () => {
      setWide(query.matches);
      setSidebar("auto");
    };
    query.addEventListener("change", onChange);
    return () => query.removeEventListener("change", onChange);
  }, []);
  // Picking a session closes the narrow-pane overlay. Stable so unchanged sidebar rows skip rendering.
  const selectSession = useCallback((sessionId: string) => {
    setSidebar((current) => (current === "open" && !wideSidebar() ? "auto" : current));
    void callNative("chat.select", { sessionId });
  }, []);
  const newChat = useCallback(() => {
    setSidebar((current) => (current === "open" && !wideSidebar() ? "auto" : current));
    void callNative("chat.new").catch(() => undefined);
  }, []);
  /// What the DEBUG automation verbs (automation.ts) read and run: this render's chat and the
  /// same selection and changes-view paths the sidebar and the edited-files card use.
  const automationView = useRef<{
    snapshot: AcpmuxSnapshot;
    selectSession: (sessionId: string) => void;
    openDiff: OpenDiff;
    diff: { open: boolean; paths: string[] };
  }>(undefined);
  automationView.current = {
    snapshot,
    selectSession,
    openDiff,
    diff: { open: diffOpen, paths: (diffFiles ?? []).map((file) => file.path) },
  };
  // Search chats opens from the app's agentPane.searchChats action (Cmd-K by default, editable in
  // Settings and cmux.json), which calls the bridge's command("searchChats"). The host pushes the
  // live bindings through applyShortcuts, so labels follow a rebind.
  const [searching, setSearching] = useState(false);
  const [shortcuts, setShortcuts] = useState<ShortcutLabels>({});
  const [preview, setPreview] = useState(false);
  /// The Quick Composer panel (`"surface": "quick"` in the host's ready reply) or a tab's pane.
  const [surface, setSurface] = useState<PaneSurface>("pane");
  const quick = surface === "quick";
  // While the narrow-pane overlay is open, Escape closes it and focus moves into it.
  useEffect(() => {
    if (sidebar !== "open" || wide) return;
    const list = document.getElementById("acpmux-sidebar");
    (
      list?.querySelector<HTMLElement>(".is-selected") ?? list?.querySelector<HTMLElement>("[aria-current=page]")
    )?.focus();
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") closeOverlay();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [sidebar, wide, closeOverlay]);
  const surfaceRef = useRef(surface);
  surfaceRef.current = surface;
  // Escape that no menu, picker or palette took hides the Quick Composer, keeping its draft.
  // ⌘Return in the Quick Composer opens its chat in a window. With a prompt it waits until the
  // prompt is on its way (closing the page sooner drops it) and the chat has a session; a send
  // that fails, or Escape, cancels the hand-off.
  const handOff = useRef({ pending: false, landed: false });
  const flushOpenInWindow = () => {
    const sessionId = sessionIdRef.current;
    if (!handOff.current.pending || !handOff.current.landed || !sessionId) return;
    handOff.current.pending = false;
    postOpenInWindow(sessionId);
  };
  const promptLanded = useRef(() => {});
  promptLanded.current = () => {
    handOff.current.landed = true;
    flushOpenInWindow();
  };
  const cancelOpenInWindow = () => {
    handOff.current.pending = false;
  };
  const openInWindow = (sent: boolean) => {
    if (sent) handOff.current = { pending: true, landed: false };
    else if (snapshot.sessionId) postOpenInWindow(snapshot.sessionId);
  };
  useEffect(flushOpenInWindow, [snapshot.sessionId]);
  useEscapeToDismiss(quick, () => {
    cancelOpenInWindow();
    void callNative(QUICK_MESSAGES.dismiss).catch(() => undefined);
  });
  const rowsRef = useRef(new Map<string, AcpmuxRow>());
  /// The newest snapshot, for host requests that read it (pane.context).
  const snapshotRef = useRef<AcpmuxSnapshot | undefined>(undefined);
  const directClient = useRef<AcpmuxDirectClient | undefined>(undefined);
  /// The composer's prompt, which dictation writes into.
  const prompt = useRef<MarkdownFieldHandle>(null);
  useComposerKeyboard(() => {
    if (!prompt.current) return false;
    prompt.current.focus();
    return true;
  });
  const dictation = useDictation(prompt, callNative);
  /// Why the host could not hand this pane acpmux (not installed, a daemon that will not start),
  /// in the host's words; cleared once a handshake succeeds.
  const [hostError, setHostError] = useState<string | undefined>();
  /// A Retry the user asked for that waits on the attempt in flight.
  const [retryQueued, setRetryQueued] = useState(false);
  /// Asks the host again now, after the user fixed what `hostError` says.
  const retryHost = useRef<(() => void) | undefined>(undefined);
  // The pane keeps the last client's catalog until the next client's arrives;
  // ids only grow, so a new client never reads an older client's cache entry.
  const catalogClientId = useRef(0);
  const [catalogSource, setCatalogSource] = useState<{ id: number; client: HarnessCatalogSource }>();
  const catalog = useHarnessCatalog(catalogSource, snapshot.catalog);
  const composerSnapshot = useMemo(
    () => (catalog === snapshot.catalog ? snapshot : { ...snapshot, catalog }),
    [snapshot, catalog],
  );
  useEffect(() => {
    window.React = React;
    window.cmuxAcpmuxRegistry = {
      register(kind, renderer, options) {
        const registered = window.cmuxAcpmuxRegistry as unknown as Record<string, unknown>;
        if (registered[kind] === renderer && (!options?.measure || options.measure === renderer.measure)) return;
        if (options?.measure) renderer.measure = options.measure;
        registered[kind] = renderer;
        setRegistry(currentRegistry());
      },
      configure() {
        setRegistry(currentRegistry());
      },
    };
    window.cmuxAcpmuxBridge = {
      command(name) {
        // The Quick Composer has no chat list to search or switch to.
        if (name === "searchChats" && surfaceRef.current !== "quick") setSearching((open) => !open);
        if (name === "createCheckpoint") showCheckpoint.current();
        if (
          [
            "permissionAllowOnce",
            "permissionAllowChat",
            "permissionDeny",
            "permissionExpand",
            "permissionRetry",
            "permissionRevoke",
            "permissionRefresh",
          ].includes(name)
        ) {
          window.dispatchEvent(new CustomEvent(`cmux-acpmux-${name}`));
        }
        if (
          name === "continueIn" &&
          snapshotRef.current?.canHandoff &&
          snapshotRef.current.handoff?.ready &&
          !snapshotRef.current.isWorking &&
          !snapshotRef.current.queue.length
        )
          setContinuing(true);
      },
      receive(next) {
        if (next.protocolVersion !== 1) return;
        const change = diffRows(rowsRef.current, next.rows);
        rowsRef.current = new Map(next.rows.map((row) => [row.id, row]));
        snapshotRef.current = next;
        try {
          sessionStorage.setItem("cmux.acpmux.snapshot", JSON.stringify(next));
        } catch {
          // Painting remains live when storage is unavailable or full.
        }
        setSnapshot(next);
        void change;
      },
      applyTheme(theme) {
        applyAgentTheme(theme as never);
      },
      applyShortcuts(labels) {
        setShortcuts(readShortcuts(labels));
      },
      applyPreview(on) {
        setPreview(on === true);
      },
      revealTurn(turnId) {
        void revealTurnWhenShown(turnId);
      },
      applyCustomization(customization) {
        if ("themeCSS" in customization) {
          let style = document.getElementById("acpmux-user-theme") as HTMLStyleElement | null;
          if (!style) {
            style = document.createElement("style");
            style.id = "acpmux-user-theme";
            document.head.append(style);
          }
          style.textContent = customization.themeCSS ?? "";
        }
        if (customization.registryJS) {
          try {
            (0, eval)(customization.registryJS);
            setRegistry(currentRegistry());
          } catch {
            /* a user renderer must not take down the transcript */
          }
        }
        if (customization.layout) {
          configureDictation(customization.layout);
          window.cmuxAcpmuxRegistry?.configure(customization.layout);
        }
      },
      dictation(update) {
        deliverDictation(update);
      },
    };
    // On the shared page host the host pushes arrive as events once the bridge exists.
    const pageHost = pageHostClient();
    if (pageHost) void startHostEvents(pageHost).catch(() => undefined);
    window.cmuxAcpmuxDebug = createAcpmuxDebug({
      replaceRows(rows) {
        rowsRef.current = new Map(rows.map((row) => [row.id, row]));
        setSnapshot((current) => ({ ...current, rows, connection: "debug", isWorking: false, canLoadOlder: false }));
      },
      rowCount: () => rowsRef.current.size,
      sessionId: () => directClient.current?.selectedSession,
      automation: {
        snapshot: () => automationView.current!.snapshot,
        call: (method, params) => callNative(method, params),
        selectSession: (sessionId) => automationView.current?.selectSession(sessionId),
        openDiff: (rowId) => automationView.current?.openDiff(rowId),
        diff: () => automationView.current?.diff ?? { open: false, paths: [] },
      },
    });
    let cancelled = false;
    let retryTimer: number | undefined;
    let retryDelay = 250;
    // Once a daemon was lost, handshakes only look for one: the user may have stopped it.
    // Looking is cheap, so a daemon started again elsewhere is found within seconds.
    const RECONNECT_MAX_DELAY_MS = 2_000;
    let reconnect = false;
    let connecting = false;
    /// The user asked to retry while an attempt was in flight; run a full one when it ends.
    let retryPending = false;
    // A seeded first prompt (onboarding's first task). Swift hands it out once, so it is kept
    // here until a connect succeeds: a first connect that fails retries without it.
    let pendingPrompt: string | undefined;
    // The harness that seeded prompt starts on (`newTab.submit --agent`), kept with it.
    let pendingHarness: string | undefined;
    const connectHost = async () => {
      if (connecting) return;
      connecting = true;
      try {
        acpmuxPerf.markAgent("handshakeStart");
        acpWire.lifecycle("handshake", { reconnect });
        const host = await callNative<{
          protocolVersion: number;
          transport?: string;
          endpoint?: string;
          token?: string;
          sessionId?: string;
          newSession?: boolean;
          newTab?: unknown;
          cwd?: string;
          draft?: string;
          prompt?: string;
          harness?: string;
          adopt?: unknown;
          account?: unknown;
          handoffStrings?: unknown;
          checkpointStrings?: unknown;
          surface?: unknown;
          linkScheme?: unknown;
          sessionMustExist?: boolean;
          revealTurn?: unknown;
        }>("ready", reconnect ? { reconnect } : {});
        if (cancelled) return;
        acpmuxPerf.markAgent("handshakeReady");
        if (
          (host.newSession && !host.sessionId) ||
          (host.sessionId && snapshotRef.current?.sessionId && host.sessionId !== snapshotRef.current.sessionId)
        )
          setSnapshot(emptySnapshot());
        if (!reconnect) setSurface(readSurface(host.surface));
        // A tab opened as the new tab page shows it until it becomes something (#16620).
        if (!reconnect) setNewTab(newTabHost(host));
        // A chat opened from another tab starts with what it inherited (#16620). Swift hands the
        // draft out once, so a retried `ready` after a failed connect has none and keeps this one.
        setHandoffLabels(localizedHandoffStrings(host.handoffStrings));
        setCheckpointLabels(localizedCheckpointStrings(host.checkpointStrings));
        const seeded = composerDraft(host.draft);
        if (seeded) setDraft(seeded);
        pendingPrompt = composerDraft(host.prompt) ?? pendingPrompt;
        if (typeof host.harness === "string" && host.harness) pendingHarness = host.harness;
        // Mock mode runs this same client against an in-page daemon.
        const mock = host.transport === "mock";
        // Links copy in this build's scheme; only the hostless mock page falls back to Release's.
        setLinkScheme(host.linkScheme, mock ? FALLBACK_LINK_SCHEME : undefined);
        if (mock)
          setCheckpointVariant(
            new URLSearchParams(window.location.search).get("checkpointVariant") === "expanded"
              ? "expanded"
              : "compact",
          );
        setAccount(mock ? MOCK_ACCOUNT : hostAccount(host.account));
        if (!mock && (host.transport !== "acpmux-websocket" || !host.endpoint || !host.token)) {
          // A host with no daemon to reach has nothing left to fail.
          setHostError(undefined);
          return;
        }
        // A new chat in mock mode starts without a session too, as against a real daemon.
        const mockConfig: AcpmuxHostConfig = host.newSession
          ? { ...mockHost, sessionId: undefined, newSession: true }
          : mockHost;
        const client = await AcpmuxDirectClient.connect(
          mock ? mockConfig : (host as AcpmuxHostConfig),
          (next) => {
            rowsRef.current = new Map(next.rows.map((row) => [row.id, row]));
            snapshotRef.current = next;
            setSnapshot((previous) => {
              if (
                next.canHandoff &&
                !next.handoff?.ready &&
                next.sessionId === previous.sessionId &&
                previous.handoff?.record
              )
                return { ...next, handoff: { ...next.handoff, record: previous.handoff.record } };
              return next;
            });
          },
          () => {
            // The daemon went away. Ask Swift again: a restarted daemon has a new port and token.
            if (cancelled) return;
            reconnect = true;
            directClient.current = undefined;
            delete window.cmuxAcpmuxActions;
            retryTimer = window.setTimeout(() => void connectHost(), retryDelay);
            retryDelay = Math.min(retryDelay * 2, reconnect ? RECONNECT_MAX_DELAY_MS : 30_000);
          },
          mock ? () => new MockAcpmuxSocket(undefined, window.cmuxAcpmuxMockScript) as unknown as WebSocket : undefined,
          mock ? "daemon" : "native",
        );
        if (cancelled) {
          client.close();
          return;
        }
        directClient.current = client;
        // Only a connected client clears the error, so a stale endpoint doesn't flicker it away.
        setHostError(undefined);
        catalogClientId.current += 1;
        setCatalogSource({ id: catalogClientId.current, client });
        retryDelay = 250;
        // A mock session is not one the host can reopen.
        const persistSession = (sessionId?: string) =>
          sessionId && !mock
            ? callNative("chat.persistSession", { sessionId }).catch(() => undefined)
            : Promise.resolve();
        const send = async (text: string, attachments: import("./attachments").ComposerAttachment[] = []) => {
          const sessionId = await client.ensureSession();
          await persistSession(sessionId);
          const turn = client.send(text, attachments);
          // The prompt is written; a Quick Composer hand-off can close this page now.
          promptLanded.current();
          return turn;
        };
        window.cmuxAcpmuxActions = {
          "chat.send": ({ text, attachments }) =>
            send(String(text ?? ""), Array.isArray(attachments) ? attachments : []),
          "chat.cancel": () => client.cancel(),
          "chat.permission": ({ permissionId, optionId }) => client.permission(String(permissionId), String(optionId)),
          "chat.permission_group.respond": ({ groupId, revision, decision }) =>
            client.permissionGroup(String(groupId), Number(revision), decision as PermissionDecision),
          "chat.permission_group.retry": () => client.permissions.retry(),
          "chat.permission_chat.revoke": () => client.permissions.revoke(),
          "chat.permission_groups.refresh": () => client.permissions.refresh(),
          "chat.model": ({ modelId }) => client.setModel(String(modelId)),
          "chat.mode": ({ modeId }) => client.setMode(String(modeId)),
          "chat.effort": ({ configId, value }) => client.setConfig(String(configId), String(value)),
          "chat.select": async ({ sessionId }) => persistSession(await client.select(String(sessionId))),
          "chat.new": async ({ harness, cwd }) =>
            persistSession(await client.create(harness ? String(harness) : undefined, cwd ? String(cwd) : undefined)),
          "chat.history": () => client.loadOlder(),
          "acp.trust.get": ({ cwd }) => client.trustGet(String(cwd)),
          "acp.trust.set": ({ cwd, level }) => client.trustSet(String(cwd), String(level)),
          "file.search": ({ path, query, limit }) =>
            client.fileSearch(
              typeof path === "string" ? path : undefined,
              String(query ?? ""),
              typeof limit === "number" ? limit : FILE_SEARCH_LIMIT,
            ),
          "chat.fork": async ({ throughSeq }) => persistSession(await client.fork(Number(throughSeq))),
          "chat.handoff.prepare": async ({ harness }) => persistSession(await client.continueIn(String(harness))),
          "chat.handoff.get": () => client.refreshHandoff(),
          "chat.handoff.draft": ({ review }) => client.saveHandoff(review as HandoffReviewInput),
          "chat.handoff.start": ({ review }) => client.startHandoff(review as HandoffReviewInput),
          "chat.handoff.discard": async () => persistSession(await client.discardHandoff()),
          "git.diff": ({ scope }) => client.gitDiff(String(scope)),
          "git.status": () => client.gitStatus(),
          "git.checkpoint.diff": ({ from, to }) => client.gitCheckpointDiff(String(from), String(to)),
          // What the agent works on, for a terminal or browser opened from this chat (#16620).
          "pane.context": async () => (snapshotRef.current ? paneContext(snapshotRef.current) : { urls: [] }),
        };
        acpmuxPerf.markAgent("composerReady");
        client.snapshot();
        void client.warmRecentProjects();
        // A new chat owns a live process before the first keypress. Sending a
        // prompt still joins this in-flight creation through ensureSession().
        // A new-tab page stays empty until the user chooses a kind or sends a prompt.
        // Other new chats still prewarm their process before the first keypress.
        if (host.newSession && !host.adopt && !host.newTab && !pendingHarness)
          void client.ensureSession().catch(() => undefined);
        // A resumed chat is the tab's session from the start, so restoring the tab reopens it.
        if (client.adopted) void persistSession(client.adopted);
        // A `#turn-<turnId>` link that opened this tab: scroll once the turn's row renders.
        if (typeof host.revealTurn === "string") void revealTurnWhenShown(host.revealTurn);
        // Onboarding's first task runs without a Send press, once. If the chat cannot start,
        // the prompt waits in the composer instead of vanishing.
        const prompt = pendingPrompt;
        const harness = pendingHarness;
        pendingPrompt = undefined;
        pendingHarness = undefined;
        // A chat seeded with an agent starts on it before the prompt goes out.
        const start = harness && prompt ? client.create(harness, host.cwd).then(persistSession) : Promise.resolve();
        if (prompt) void start.then(() => send(prompt)).catch(() => setDraft(prompt));
      } catch (error) {
        if (!cancelled) {
          acpWire.lifecycle("handshake failed", { message: String(error) });
          setSnapshot((current) => ({ ...current, connection: `connecting: ${String(error)}` }));
          setHostError(error instanceof Error ? error.message : String(error));
          // Back off so a host without a daemon is not asked four times a second.
          retryTimer = window.setTimeout(() => void connectHost(), retryDelay);
          retryDelay = Math.min(retryDelay * 2, reconnect ? RECONNECT_MAX_DELAY_MS : 30_000);
        }
      } finally {
        connecting = false;
        if (retryPending) {
          retryPending = false;
          setRetryQueued(false);
          // The attempt in flight may have connected; then there is nothing left to retry.
          if (!cancelled && !directClient.current) retryNow();
        }
      }
    };
    // The user asked: try now, and let the host start a daemon even after one was lost.
    const retryNow = () => {
      if (retryTimer !== undefined) window.clearTimeout(retryTimer);
      retryTimer = undefined;
      reconnect = false;
      retryDelay = 250;
      void connectHost();
    };
    retryHost.current = () => {
      if (cancelled) return;
      if (!connecting) return retryNow();
      // An attempt is in flight (perhaps a reconnect that may not start the daemon): run the
      // user's full attempt once it ends.
      retryPending = true;
      setRetryQueued(true);
    };
    void connectHost();
    return () => {
      cancelled = true;
      retryHost.current = undefined;
      if (retryTimer !== undefined) window.clearTimeout(retryTimer);
      directClient.current?.close();
      directClient.current = undefined;
      delete window.cmuxAcpmuxActions;
    };
  }, []);
  const ComposerChips =
    ((window.cmuxAcpmuxRegistry as unknown as Record<string, unknown> | undefined)?.composerChips as
      | React.ComponentType<{ snapshot: AcpmuxSnapshot }>
      | undefined) ?? DefaultComposerChips;
  const sidebarShown = sidebar === "open" || (sidebar === "auto" && wide);
  const toggleSidebar = () => setSidebar(sidebarShown ? "closed" : "open");
  // The catalog arrives through the query cache, which composerSnapshot carries.
  const header = paneHeader(composerSnapshot);
  const sourceHarness = snapshot.summary?.harness?.split(/[-_]/)[0];
  const handoffTargets = composerSnapshot.catalog.filter((entry) => {
    const family = entry.id.split(/[-_]/)[0];
    return sourceHarness === "claude" ? family === "codex" : sourceHarness === "codex" && family === "claude";
  });
  const canContinue =
    !!snapshot.canHandoff &&
    !!snapshot.handoff?.ready &&
    !snapshot.isWorking &&
    !snapshot.queue.length &&
    !snapshot.handoff?.busy &&
    !reviewing &&
    handoffTargets.length > 0;
  const ignoreFailure = (result: Promise<unknown>) => void result.catch(() => undefined);
  const showNewTab = newTab !== undefined && !snapshot.sessionId && snapshot.rows.length === 0;
  // The page's recent sessions stand in for the session list, which opens on demand (All sessions).
  const shellSidebar = showNewTab && sidebar === "auto" ? "closed" : sidebar;
  const openFromNewTab = (kind: TabKind, text: string, cwd?: string) => {
    if (kind !== "agent") {
      void callNative("tab.open", cwd ? { kind, text, cwd } : { kind, text });
      return;
    }
    setNewTab(undefined);
    const start = cwd ? callNative("chat.new", { cwd }) : Promise.resolve();
    void start.then(() => (text ? callNative("chat.send", { text }) : undefined));
  };
  const newTabProjects = useMemo(() => {
    const byPath = new Map<string, { cwd: string; label: string }>();
    for (const path of newTab?.projects ?? []) byPath.set(path, { cwd: path, label: projectLabel(path) });
    for (const session of composerSnapshot.sessions) {
      if (typeof session.cwd !== "string" || !session.cwd) continue;
      if (session.host && session.hostKind !== "local") continue;
      byPath.set(session.cwd, { cwd: session.cwd, label: projectLabel(session.cwd) });
    }
    if (newTab?.cwd) byPath.set(newTab.cwd, { cwd: newTab.cwd, label: projectLabel(newTab.cwd) });
    return [...byPath.values()];
  }, [composerSnapshot.sessions, newTab?.cwd, newTab?.projects]);
  const transcript = (
    <TurnActionsContext.Provider value={turnActions}>
      <TurnCountsContext.Provider value={turnCountsFor}>
        <VirtualTranscript
          rows={transcriptRows}
          canLoadOlder={snapshot.canLoadOlder}
          expanded={expanded}
          registry={registry}
          // The Quick Composer has no room for the changes view; its file rows stay plain.
          onOpenDiff={quick ? undefined : openDiff}
          onToggleActivity={(id) =>
            setExpanded((current) => {
              const next = new Set(current);
              if (next.has(id)) next.delete(id);
              else next.add(id);
              return next;
            })
          }
        />
      </TurnCountsContext.Provider>
    </TurnActionsContext.Provider>
  );
  const asks = (
    <>
      {snapshot.permissionGroups?.supported && (
        <PermissionPanel
          state={snapshot.permissionGroups}
          onRespond={(groupId, revision, decision) => {
            void callNative("chat.permission_group.respond", { groupId, revision, decision });
          }}
          onRetry={() => {
            void callNative("chat.permission_group.retry", {});
          }}
          onRevoke={() => {
            void callNative("chat.permission_chat.revoke", {});
          }}
          onRefresh={() => {
            void callNative("chat.permission_groups.refresh", {});
          }}
        />
      )}
      {(individualPermission || trustAsk.ask) && (
        <div className="acpmux-permission">
          {trustAsk.ask && (
            <TrustAsk
              ask={trustAsk.ask}
              agent={snapshot.summary?.harness ? agentName(snapshot.summary.harness) : t("trust.agent")}
              onTrust={trustAsk.trust}
              onDistrust={trustAsk.distrust}
              onUndo={trustAsk.undo}
            />
          )}
          {individualPermission && (
            <PermissionCard permission={individualPermission} onAnswer={answerPermission(individualPermission)} />
          )}
        </div>
      )}
    </>
  );
  const composer = !reviewing && !handoffLoading && (
    <>
      <DictationNotice dictation={dictation} />
      <Composer
        snapshot={composerSnapshot}
        chips={ComposerChips}
        draft={draft}
        onSend={(text, attachments) => {
          // Until acpmux connects nothing takes a prompt; the composer keeps it.
          if (!window.cmuxAcpmuxActions?.["chat.send"]) return false;
          callNative("chat.send", { text, attachments }).then(() => promptLanded.current(), cancelOpenInWindow);
        }}
        onStop={() => void callNative("chat.cancel")}
        onProject={(cwd) => void callNative("chat.new", { cwd }).catch(() => undefined)}
        // Without a folder there is nothing to search; the + menu leaves the item out.
        searchFiles={fileRoot ? searchFiles : undefined}
        onOpenInWindow={quick ? openInWindow : undefined}
        prompt={prompt}
        accessory={<DictationButton dictation={dictation} />}
      />
    </>
  );
  const hostErrorCard = hostError && (
    <HostError message={hostError} retrying={retryQueued} onRetry={() => retryHost.current?.()} />
  );
  if (quick)
    return (
      <ShortcutsContext.Provider value={shortcuts}>
        <section className="acpmux-shell" data-surface="quick">
          <QuickSurface
            transcript={snapshot.rows.length > 0 ? transcript : undefined}
            asks={
              <>
                {asks}
                {hostErrorCard}
              </>
            }
            composer={composer}
          />
        </section>
      </ShortcutsContext.Provider>
    );
  return (
    <ShortcutsContext.Provider value={shortcuts}>
      <section className="acpmux-shell" data-sidebar={shellSidebar}>
        <SessionSidebar
          sessions={snapshot.sessions}
          selectedId={snapshot.sessionId}
          onSelect={selectSession}
          onNewChat={newChat}
          account={account}
          preview={preview}
        />
        {sidebar === "open" && (
          <button
            type="button"
            className="acpmux-sidebar-scrim"
            aria-label="Close sessions"
            tabIndex={-1}
            onClick={closeOverlay}
          />
        )}
        <div className="acpmux-main" data-new-chat={freshChat && !showNewTab ? "" : undefined}>
          {showNewTab && newTab.layout === "b" ? (
            <NewTabScreen
              key={newTabGeneration}
              snapshot={composerSnapshot}
              omnibar={newTab.omnibar}
              location={newTab.location}
              lastAgent={newTab.lastAgent}
              home={newTab.home}
              {...newTabScreenActions({
                callNative,
                cwd: newTab.cwd,
                leave: () => setNewTab(undefined),
                selectSession,
                showAllChats: () => setSidebar("open"),
              })}
            />
          ) : showNewTab ? (
            <NewTabPage
              key={newTabGeneration}
              snapshot={composerSnapshot}
              hotkeys={newTab.hotkeys}
              initialKind={newTab.initialKind}
              cwd={newTab.cwd}
              host={newTab.host}
              location={newTab.location}
              omnibar={newTab.omnibar}
              projects={newTabProjects}
              chips={ComposerChips}
              onSubmit={openFromNewTab}
              onJump={(target, id) => void callNative("tab.jump", { target, id })}
              onOpenSession={(sessionId) => {
                setNewTab(undefined);
                selectSession(sessionId);
              }}
              onShowAll={() => setSidebar("open")}
              onImport={() => void callNative("action.run", { id: "palette.welcomeChecklist" })}
              onBrowseProject={() => void callNative("action.run", { id: "palette.welcomeChecklist" })}
              onEditShortcut={(kind) => void callNative("shortcut.edit", { kind })}
            />
          ) : (
            <>
              <div className={`acpmux-stage${diffFiles ? " acpmux-reviewing" : ""}`}>
                <header className="acpmux-header">
                  <div>
                    <button
                      type="button"
                      className="acpmux-sidebar-toggle"
                      ref={sidebarToggle}
                      aria-label="Sessions"
                      title="Sessions"
                      aria-controls="acpmux-sidebar"
                      aria-expanded={sidebarShown}
                      onClick={toggleSidebar}
                    />
                    <strong className="acpmux-title">{header.title}</strong>
                    {header.status && <span className="acpmux-status">{header.status}</span>}
                  </div>
                  <div className="acpmux-handoff-header-tools">
                    <SummaryButton rows={snapshot.rows} onOpenOutput={quick ? undefined : openOutput} />
                    <CopyChatLink sessionId={snapshot.sessionId} />
                    {checkpoints.supported && (
                      <button type="button" className="acpmux-checkpoint-open" onClick={checkpoints.show}>
                        {checkpointLabels.createCheckpoint}
                      </button>
                    )}
                    {preview && (
                      <span
                        className="acpmux-session-coverage"
                        title={`${handoffLabels.unverified} · ${snapshot.summary?.enforcement?.detail ?? handoffLabels.unverifiedDetail}`}
                      >
                        {snapshot.summary?.enforcement ? handoffLabels.nativePolicy : handoffLabels.unverified}
                      </span>
                    )}
                    {snapshot.canHandoff && handoffTargets.length > 0 && (
                      <ContinueMenu
                        label={handoffLabels.continueIn}
                        targets={handoffTargets}
                        disabled={!canContinue}
                        open={continuing}
                        setOpen={setContinuing}
                        onChoose={(harness) => ignoreFailure(callNative("chat.handoff.prepare", { harness }))}
                      />
                    )}
                  </div>
                </header>
                {!diffView && checkpoints.review}
                {snapshot.missingSession && (
                  <p className="acpmux-link-missing" role="alert">
                    {t("link.sessionMissing")}
                  </p>
                )}
                {!reviewing && snapshot.handoff?.error && (
                  <p className="acpmux-handoff-error" role="alert">
                    {snapshot.handoff.error}
                  </p>
                )}
                {reviewing && handoff && snapshot.handoff ? (
                  <HandoffReviewMessage
                    key={`${handoff.handoffId}:${reviewReload}`}
                    record={handoff}
                    state={snapshot.handoff}
                    strings={handoffLabels}
                    onSave={(review) => callNative("chat.handoff.draft", { review })}
                    onStart={(review) => callNative("chat.handoff.start", { review })}
                    onReturn={() => selectSession(handoff.source.sessionId)}
                    onDiscard={() => ignoreFailure(callNative("chat.handoff.discard"))}
                    onReload={() =>
                      ignoreFailure(callNative("chat.handoff.get").then(() => setReviewReload((value) => value + 1)))
                    }
                  />
                ) : freshChat ? (
                  <EmptyState project={projectName(snapshot.summary?.cwd)} />
                ) : (
                  transcript
                )}
                {diffView && diffFiles && (
                  <DiffPanel
                    files={diffDisplay?.files ?? diffFiles}
                    turn={diffDisplay}
                    initialPath={diffView.path}
                    onClose={closeDiff}
                    source={changesSource}
                    onOpenFile={openChangedFile}
                    checkpointAction={
                      checkpoints.supported ? (
                        <button type="button" className="acpmux-checkpoint-open" onClick={checkpoints.show}>
                          {checkpointLabels.createCheckpoint}
                        </button>
                      ) : undefined
                    }
                    checkpointReview={checkpoints.review}
                    review={hunkReview}
                    reviewFiles={diffFiles}
                  />
                )}
              </div>
              {asks}
              {/* Between the hero and the docked composer. */}
              {freshChat && (
                <div className="acpmux-home-area">
                  <HomeLists sessions={snapshot.sessions} currentId={snapshot.sessionId} onSelect={selectSession} />
                </div>
              )}
              {hostErrorCard}
              {composer}
            </>
          )}
        </div>
        {searching && (
          <SearchChats
            sessions={snapshot.sessions}
            onClose={() => setSearching(false)}
            onSelect={(sessionId) => {
              setSearching(false);
              selectSession(sessionId);
            }}
            onNewChat={() => {
              setSearching(false);
              newChat();
            }}
          />
        )}
      </section>
    </ShortcutsContext.Provider>
  );
}

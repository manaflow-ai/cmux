import React, { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { QueryClientProvider } from "@tanstack/react-query";
import type { Token, Tokens } from "marked";
import { applyAgentTheme } from "../shared/theme";
import { diffRows, layoutConversation, markdownBlocks, paneHeader, placeRows, safeHref, transcriptRowWidth, visibleLayoutRange, type AcpmuxPermission, type AcpmuxRow, type AcpmuxSnapshot } from "./model";
import { AcpmuxDirectClient, type AcpmuxHostConfig } from "./direct";
import { createPaneQueryClient, useHarnessCatalog, type HarnessCatalogSource } from "./catalog";
import { startMockHost } from "./mock";
import { createAcpmuxDebug, type AcpmuxDebug } from "./debug";
import { acpWire } from "./wire";
import { acpmuxPerf } from "./perf";
import { ScrollPacing } from "./pacing";
import { SessionSidebar } from "./SessionSidebar";
import { turnFiles, turnRows } from "./diff";
import { DiffPanel } from "./DiffPanel";
import { Inspector, InspectorToggle, type ExportOutcome } from "./Inspector";

type Reply<T> = { ok: true; value: T } | { ok: false; error?: { userMessage?: string } };
type MeasurableRenderer = React.ComponentType<RowProps> & { measure?: (row: AcpmuxRow, width: number) => number };
type NativeRegistry = Record<string, MeasurableRenderer>;
/// `onOpenDiff` opens the changes of the turn holding `rowId`, at `path` when given.
type RowProps = { row: AcpmuxRow; onToggleActivity: (id: string) => void; expanded: boolean; onOpenDiff?: (rowId: string, path?: string) => void };

declare global {
  interface Window {
    cmuxAcpmuxBridge?: {
      receive(snapshot: AcpmuxSnapshot): void;
      applyTheme(theme: Record<string, unknown>): void;
      applyCustomization(customization: { themeCSS?: string; registryJS?: string; layout?: Record<string, unknown> }): void;
      /** Opens (true), closes (false) or toggles (no argument) the ACP inspector; returns whether it is open. Show ACP Inspector calls it. */
      toggleInspector(open?: boolean): boolean;
    };
    cmuxAcpmuxRegistry?: { register(kind: string, renderer: MeasurableRenderer, options?: { measure?: (row: AcpmuxRow, width: number) => number }): void; configure(options: Record<string, unknown>): void };
    cmuxAcpmuxDebug?: AcpmuxDebug;
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    React?: typeof React;
  }
}

function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  const handler = window.webkit?.messageHandlers?.agentSession;
  if (!handler) return Promise.reject(new Error("Native bridge is unavailable"));
  return Promise.resolve(handler.postMessage({ id: crypto.randomUUID(), method, params }) as unknown as Reply<T>).then((reply) => {
    if (!reply.ok) throw new Error(reply.error?.userMessage ?? "Request failed");
    return reply.value;
  });
}

/** Saves the inspector's export through the host's save panel (`pane.saveLog`): true is saved, false a cancelled panel. A host without it, or one that refuses the log, leaves the inspector to copy it. */
export async function saveLogNatively(text: string, suggestedName: string): Promise<ExportOutcome> {
  try {
    return (await callNative<boolean>("pane.saveLog", { text, suggestedName })) === true ? "saved" : "cancelled";
  } catch {
    return "unavailable";
  }
}

/// `measuredText` in model.ts mirrors this walk; keep them drawing and measuring the same text.
function renderInline(tokens: Token[] | undefined, fallback: string): React.ReactNode {
  if (!tokens?.length) return fallback;
  return tokens.map((token, index) => {
    if (token.type === "codespan") return <code key={index}>{token.text}</code>;
    if (token.type === "link") {
      const href = safeHref(token.href);
      return href ? <a key={index} href={href} rel="noreferrer">{renderInline(token.tokens, token.text)}</a> : token.text;
    }
    if ("tokens" in token) return <React.Fragment key={index}>{renderInline(token.tokens, "text" in token ? token.text : token.raw ?? "")}</React.Fragment>;
    return token.raw ?? ("text" in token ? token.text : "");
  });
}

/// `listHeight` in model.ts measures the same items: inline text, then any nested list.
function MarkdownList({ list }: { list: Tokens.List }) {
  const items = list.items.map((item, index) => <li key={index}>{item.tokens.map((token, tokenIndex) => token.type === "list" ? <MarkdownList key={tokenIndex} list={token as Tokens.List} /> : <React.Fragment key={tokenIndex}>{renderInline([token], "")}</React.Fragment>)}</li>);
  return list.ordered ? <ol start={typeof list.start === "number" && list.start !== 1 ? list.start : undefined}>{items}</ol> : <ul>{items}</ul>;
}

function MarkdownBlocks({ source }: { source: string }) {
  return <>{markdownBlocks(source).map((token, index) => {
    if (token.type === "code") return <pre key={index}><code>{token.text}</code></pre>;
    if (token.type === "heading") return <div className={`acpmux-heading acpmux-heading-${token.depth}`} key={index}>{renderInline(token.tokens, token.text)}</div>;
    if (token.type === "paragraph" || token.type === "text") return <p key={index}>{renderInline(token.tokens, token.text)}</p>;
    if (token.type === "list") return <MarkdownList key={index} list={token as Tokens.List} />;
    if (token.type === "blockquote") return <blockquote key={index}>{renderInline(token.tokens, token.text)}</blockquote>;
    if (token.type === "hr") return <hr key={index} />;
    return <p key={index}>{token.raw}</p>;
  })}</>;
}

const MessageRow = memo(function MessageRow({ row }: RowProps) {
  return <div className={`acpmux-markdown ${row.kind === "user" ? "acpmux-user-bubble" : ""}`}><MarkdownBlocks source={row.text ?? ""} /></div>;
}, (previous, next) => previous.row.id === next.row.id && previous.row.version === next.row.version);

const toolCalls = (count = 0) => count === 1 ? "1 tool call" : `${count} tool calls`;

const ToolActivityRow = memo(function ToolActivityRow({ row, onToggleActivity, expanded }: RowProps) {
  return <div className="acpmux-activity"><button className="acpmux-activity-toggle" aria-expanded={expanded} onClick={() => onToggleActivity(row.id)}>{expanded ? "⌄" : "›"} Worked with {toolCalls(row.toolCount)}</button>{expanded && <div className="acpmux-activity-items">{(row.items ?? []).map((item) => <div className="acpmux-activity-item" key={`${row.id}-${item.text}`}><span className="acpmux-glyph">{item.kind === "tool" ? "▣" : "✦"}</span>{item.text}{item.tool?.output && <pre>{item.tool.output}</pre>}</div>)}</div>}</div>;
}, (previous, next) => previous.row.id === next.row.id && previous.row.version === next.row.version && previous.expanded === next.expanded);

const SummaryRow = memo(function SummaryRow({ row }: RowProps) { return <div className="acpmux-summary">{row.durationMs === undefined ? toolCalls(row.toolCount) : `Worked for ${Math.round(row.durationMs / 1000)}s · ${toolCalls(row.toolCount)}`}</div>; }, (a, b) => a.row.id === b.row.id && a.row.version === b.row.version);
const NoticeRow = memo(function NoticeRow({ row }: RowProps) { return <div className="acpmux-muted">{row.text}</div>; }, (a, b) => a.row.id === b.row.id && a.row.version === b.row.version);
const PermissionRow = memo(function PermissionRow({ row }: RowProps) { const permission = row.permission; return <div className="acpmux-permission-card"><strong>{permission?.title || "Permission required"}</strong><div className="acpmux-permission-buttons">{permission?.options.map((option) => <button key={option.id} onClick={() => void callNative("chat.permission", { permissionId: permission.permissionId, optionId: option.id })}>{option.name}</button>)}</div></div>; }, (a, b) => a.row.id === b.row.id && a.row.version === b.row.version);
const EditedFilesRow = memo(function EditedFilesRow({ row, onOpenDiff }: RowProps) {
  const files = (row.items ?? []).filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange");
  const reviewable = onOpenDiff && files.some((file) => file.tool?.diffs?.length);
  return <div className="acpmux-edited-files"><div className="acpmux-edited-title"><strong>Edited files</strong>{reviewable && <button type="button" className="acpmux-review-changes" onClick={() => onOpenDiff(row.id)}>Review changes</button>}</div>{files.map((file) => {
    const diffs = file.tool?.diffs ?? [];
    if (!diffs.length || !onOpenDiff) return <div key={file.tool?.id || file.text}>▤ {file.tool?.inputSummary || file.text}</div>;
    // One line per file the call changed; each opens the changes at its file.
    return <div className="acpmux-edited-call" key={file.tool?.id || file.text}>▤ {diffs.map((diff, index) => <React.Fragment key={diff.path}>{index > 0 && ", "}<button type="button" className="acpmux-edited-file" title={diff.path} onClick={() => onOpenDiff(row.id, diff.path)}>{diff.path.split("/").pop()}</button></React.Fragment>)}</div>;
  })}</div>;
}, (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.onOpenDiff === b.onOpenDiff);

const defaultRegistry: NativeRegistry = { user: MessageRow, assistant: MessageRow, activity: ToolActivityRow, editedFiles: EditedFilesRow, turnSummary: SummaryRow, notice: NoticeRow, plan: NoticeRow, typing: NoticeRow, permission: PermissionRow };

/// A row's height as the page drew it, valid while the row's content version and width hold.
type DrawnHeight = { version: number; width: number; height: number };
type ReportDrawn = (id: string, version: number, height: number) => void;

/// One transcript row. It reports its drawn height before the frame paints whenever it mounts or
/// its content, width or expansion changes; the transcript's ResizeObserver reports later changes
/// (a font that loads, a custom renderer that grows).
function RowFrame({ row, kind, index, setSize, top, rowWidth, expanded, observer, report, children }: { row: AcpmuxRow; kind: string; index: number; setSize: number; top: number; rowWidth: number; expanded: boolean; observer: ResizeObserver | undefined; report: ReportDrawn; children: React.ReactNode }) {
  const ref = useRef<HTMLElement>(null);
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
  return <article ref={ref} data-row-id={row.id} className={`acpmux-row acpmux-${kind}`} aria-label={speaker(kind)} aria-posinset={index + 1} aria-setsize={setSize} style={{ transform: `translateY(${top}px)` }}>{children}</article>;
}

/// Who spoke, for assistive technology: each article is one message in the transcript feed.
const speaker = (kind: string) => kind === "user" ? "You" : kind === "assistant" ? "Agent" : undefined;
const rowKind = (row: AcpmuxRow) => row.kind === "activity" && row.items?.some((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange") ? "editedFiles" : row.kind;
const currentRegistry = (): NativeRegistry => ({ ...defaultRegistry, ...(window.cmuxAcpmuxRegistry as unknown as NativeRegistry | undefined) });

/// Where a scroller sits, read while its content still matches `totalHeight`.
const scrollPosition = (node: HTMLElement, totalHeight: number) => ({ top: node.scrollTop, atLatest: node.scrollTop >= totalHeight - node.clientHeight - 1 });

/// Scroll steps of rows mounted ahead in the scroll direction, capped in viewports.
/// A scroll commits from its event, a frame after the offset moved, so without the
/// lead a fling shows a blank edge on every frame.
const SCROLL_LEAD_STEPS = 2;
const MAX_SCROLL_LEAD_VIEWPORTS = 4;

export function VirtualTranscript({ rows, onToggleActivity, onOpenDiff, expanded, registry = defaultRegistry, canLoadOlder = false }: { rows: AcpmuxRow[]; onToggleActivity: (id: string) => void; onOpenDiff?: (rowId: string, path?: string) => void; expanded: Set<string>; registry?: NativeRegistry; canLoadOlder?: boolean }) {
  // Debug measurement (acpmuxPerf): off until the first debug call.
  const renderStart = acpmuxPerf.enabled ? performance.now() : 0;
  const [scroll, setScroll] = useState({ top: 0, delta: 0 });
  const [height, setHeight] = useState(600);
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(760);
  // Rows place by their drawn height once drawn, and by the estimate until then.
  const [drawn, setDrawn] = useState(new Map<string, DrawnHeight>());
  const pendingDrawn = useRef(new Map<string, DrawnHeight>());
  const rowWidthRef = useRef(transcriptRowWidth(width));
  rowWidthRef.current = transcriptRowWidth(width);
  const rowsRef = useRef(rows);
  rowsRef.current = rows;
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
        if (old && old.version === entry.version && old.width === entry.width && Math.abs(old.height - entry.height) < 0.5) continue;
        next ??= new Map(current);
        next.set(id, entry);
      }
      return next ?? current;
    });
  }, []);
  const observer = useMemo(() => typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver((entries?: ResizeObserverEntry[]) => {
    for (const entry of entries ?? []) {
      const target = entry.target as HTMLElement;
      const row = rowsRef.current[Number(target.getAttribute("aria-posinset")) - 1];
      if (row && row.id === target.dataset.rowId) reportDrawn(row.id, row.version, target.getBoundingClientRect().height);
    }
    // A late size change (a font loading) must not paint a frame of overlap first.
    flushSync(flushDrawn);
  }), [reportDrawn, flushDrawn]);
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
  useEffect(() => { const node = ref.current; if (!node) return; const observer = new ResizeObserver(() => { setHeight(node.clientHeight); setWidth(node.clientWidth); }); observer.observe(node); setWidth(node.clientWidth); return () => observer.disconnect(); }, []);
  const previousLayout = useRef<ReturnType<typeof layoutConversation> | null>(null);
  const scrolledTo = useRef({ top: 0, atLatest: false });
  // Scroll frames re-render with the same rows; only rows, width or the registry
  // change an estimate.
  const estimated = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    const layout = layoutConversation(rows, transcriptRowWidth(width), measurementCache.current, (row, rowWidth) => registry[rowKind(row)]?.measure?.(row, rowWidth));
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
  }, [rows, width, registry]);
  // A row that draws moves only the rows below it: place them again, measuring none.
  const measured = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    const rowWidth = transcriptRowWidth(width);
    const layout = drawn.size === 0 ? estimated.layout : placeRows(estimated.layout, (index) => {
      const known = drawn.get(rows[index].id);
      return known && known.version === rows[index].version && known.width === rowWidth ? known.height : undefined;
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
    if (acpmuxPerf.enabled && renderStart > 0) { const now = performance.now(); acpmuxPerf.commit(now - renderStart, layoutMs, acpmuxPerf.mountedTop, acpmuxPerf.mountedBottom, now); }
  });
  useLayoutEffect(() => {
    const old = previousLayout.current;
    const node = ref.current;
    if (old && node && old.tops.length === layout.tops.length) {
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
      const atLatest = clamped || unmoved ? scrolledTo.current.atLatest : top >= old.totalHeight - node.clientHeight - 1;
      // At the first row nothing above can move it.
      if (top > 0 && didOpenAtLatest.current && atLatest) {
        // At the latest row: stay there as rows settle to their drawn heights.
        const latest = Math.max(0, layout.totalHeight - node.clientHeight);
        if (Math.abs(latest - node.scrollTop) > 0.5) node.scrollTop = latest;
      } else if (top > 0) {
        // Keep the row at the top of the viewport where it is as rows above it change height.
        const anchor = visibleLayoutRange(old, top, 0, 0).first;
        const delta = layout.tops[anchor] - old.tops[anchor];
        if (clamped || Math.abs(delta) > 0.5) node.scrollTop = top + delta;
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
    if (node) scrolledTo.current = scrollPosition(node, layout.totalHeight);
  }, [layout, range.first, height]);
  // Commit before this frame paints; deferring to the next animation frame left the edge blank.
  // Each settled scroll's frame pacing goes to the host, which picks the pane's rendering rate.
  const pacing = useMemo(() => new ScrollPacing((intervals) => { callNative("pane.framePacing", { intervals }).catch(() => {}); }), []);
  useEffect(() => () => pacing.stop(), [pacing]);
  const onScroll = (event: React.UIEvent<HTMLDivElement>) => { pacing.scrolled(); const next = event.currentTarget.scrollTop; scrolledTo.current = scrollPosition(event.currentTarget, layout.totalHeight); flushSync(() => setScroll((current) => ({ top: next, delta: next - current.top }))); };
  return <div ref={ref} className="acpmux-scroll" role="feed" aria-label="Transcript" onScroll={onScroll}><div className="acpmux-spacer" style={{ height: layout.totalHeight }}><div className="acpmux-thread">{rows.slice(range.first, range.last).map((row, index) => { const absoluteIndex = range.first + index; const kind = rowKind(row); const Component = registry[kind] ?? NoticeRow; const isExpanded = expanded.has(row.id); return <RowFrame key={row.id} row={row} kind={kind} index={absoluteIndex} setSize={canLoadOlder ? -1 : rows.length} top={layout.tops[absoluteIndex]} rowWidth={transcriptRowWidth(width)} expanded={isExpanded} observer={observer} report={reportDrawn}><Component row={row} onToggleActivity={onToggleActivity} onOpenDiff={onOpenDiff} expanded={isExpanded} /></RowFrame>; })}</div></div></div>;
}

function PermissionCard({ permission }: { permission: AcpmuxPermission }) { return <div className="acpmux-permission-card"><strong>{permission.title || "Permission required"}</strong><div className="acpmux-permission-buttons">{permission.options.map((option) => <button key={option.id} onClick={() => void callNative("chat.permission", { permissionId: permission.permissionId, optionId: option.id })}>{option.name}</button>)}</div></div>; }

function DefaultComposerChips({ snapshot }: { snapshot: AcpmuxSnapshot }) { const modelOptions = snapshot.catalog.find((harness) => harness.id === snapshot.summary?.harness)?.models ?? []; const modeOptions = snapshot.summary?.modes?.availableModes ?? []; const effort = snapshot.summary?.configOptions?.find((option) => option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort"); return <div className="acpmux-chips">{modelOptions.length > 0 && <select className="acpmux-model" aria-label="Model" value={snapshot.summary?.model ?? ""} onChange={(event) => void callNative("chat.model", { modelId: event.target.value })}>{modelOptions.map((model) => <option key={model.id} value={model.id}>{model.name || model.id}</option>)}</select>}{modeOptions.length > 0 && <select className="acpmux-mode" aria-label="Mode" value={snapshot.summary?.modes?.currentModeId ?? ""} onChange={(event) => void callNative("chat.mode", { modeId: event.target.value })}>{modeOptions.map((mode) => <option key={mode.id} value={mode.id}>{mode.name || mode.id}</option>)}</select>}{effort && <select className="acpmux-effort" aria-label="Effort" value={effort.currentValue ?? ""} onChange={(event) => void callNative("chat.effort", { configId: effort.id, value: event.target.value })}>{effort.options.map((option) => <option key={option.value} value={option.value}>{option.name || option.value}</option>)}</select>}</div>; }

/** Whether the pane is wide enough to show the session list beside the transcript. */
const WIDE_PANE = "(min-width: 640px)";
function wideSidebar(): boolean { return window.matchMedia?.(WIDE_PANE).matches ?? true; }

export function AcpmuxApp() {
  const [queryClient] = useState(createPaneQueryClient);
  return <QueryClientProvider client={queryClient}><AcpmuxPane /></QueryClientProvider>;
}

function AcpmuxPane() {
  const [snapshot, setSnapshot] = useState<AcpmuxSnapshot>({ type: "snapshot", protocolVersion: 1, rows: [], sessions: [], connection: "connecting", isWorking: false, queue: [], catalog: [], canLoadOlder: false });
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  // The open changes view: a turn of one session, and the control that opened it.
  const [inspectorOpen, setInspectorOpen] = useState(false);
  // The bridge answers synchronously, before React re-renders with the new state.
  const inspectorOpenRef = useRef(inspectorOpen);
  inspectorOpenRef.current = inspectorOpen;
  const [diffView, setDiffView] = useState<{ sessionId?: string; rowId: string; path?: string; opener?: HTMLElement }>();
  const sessionIdRef = useRef(snapshot.sessionId);
  sessionIdRef.current = snapshot.sessionId;
  const openDiff = useCallback((rowId: string, path?: string) => setDiffView({ sessionId: sessionIdRef.current, rowId, path, opener: document.activeElement instanceof HTMLElement ? document.activeElement : undefined }), []);
  const closedByUser = useRef(false);
  const closeDiff = useCallback(() => { closedByUser.current = true; setDiffView(undefined); }, []);
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
  const diffOpen = diffView !== undefined && diffView.sessionId === snapshot.sessionId && snapshot.rows.some((row) => row.id === diffView.rowId);
  useEffect(() => { if (diffView && !diffOpen) setDiffView(undefined); }, [diffView, diffOpen]);
  // Streaming text changes rows on every chunk; only the turn's tool calls change its files.
  const diffActivity = useRef<{ key: string; files: ReturnType<typeof turnFiles> }>(undefined);
  const diffFiles = useMemo(() => {
    if (!diffView || !diffOpen) return undefined;
    const activity = turnRows(snapshot.rows, diffView.rowId).filter((row) => row.kind === "activity");
    const key = `${diffView.rowId}\u0000${activity.map((row) => `${row.id}:${row.version}`).join("|")}`;
    if (diffActivity.current?.key !== key) diffActivity.current = { key, files: turnFiles(activity) };
    return diffActivity.current.files;
  }, [diffView, diffOpen, snapshot.rows]);
  const [registry, setRegistry] = useState<NativeRegistry>(defaultRegistry);
  /// The session list shows beside the transcript in a wide pane and on demand in a narrow one.
  const [sidebar, setSidebar] = useState<"auto" | "open" | "closed">("auto");
  const sidebarToggle = useRef<HTMLButtonElement>(null);
  // Escape and the scrim close the narrow-pane overlay and give focus back to its toggle.
  const closeOverlay = useCallback(() => { setSidebar("auto"); sidebarToggle.current?.focus(); }, []);
  // Crossing the width threshold resets the list to the default for the new width, so a list opened beside the transcript never turns into an overlay.
  const [wide, setWide] = useState(wideSidebar);
  useEffect(() => {
    const query = window.matchMedia?.(WIDE_PANE);
    if (!query?.addEventListener) return;
    // The width may have crossed the threshold between the first render and this subscription.
    setWide(query.matches);
    const onChange = () => { setWide(query.matches); setSidebar("auto"); };
    query.addEventListener("change", onChange);
    return () => query.removeEventListener("change", onChange);
  }, []);
  // Picking a session closes the narrow-pane overlay. Stable so unchanged sidebar rows skip rendering.
  const selectSession = useCallback((sessionId: string) => { setSidebar((current) => current === "open" && !wideSidebar() ? "auto" : current); void callNative("chat.select", { sessionId }); }, []);
  // While the narrow-pane overlay is open, Escape closes it and focus moves into it.
  useEffect(() => {
    if (sidebar !== "open" || wide) return;
    const list = document.getElementById("acpmux-sidebar");
    (list?.querySelector<HTMLElement>(".is-selected") ?? list?.querySelector<HTMLElement>("button"))?.focus();
    const onKey = (event: KeyboardEvent) => { if (event.key === "Escape") closeOverlay(); };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [sidebar, wide, closeOverlay]);
  const rowsRef = useRef(new Map<string, AcpmuxRow>());
  const directClient = useRef<AcpmuxDirectClient | undefined>(undefined);
  // The pane keeps the last client's catalog until the next client's arrives;
  // ids only grow, so a new client never reads an older client's cache entry.
  const catalogClientId = useRef(0);
  const [catalogSource, setCatalogSource] = useState<{ id: number; client: HarnessCatalogSource }>();
  const catalog = useHarnessCatalog(catalogSource, snapshot.catalog);
  const composerSnapshot = useMemo(() => catalog === snapshot.catalog ? snapshot : { ...snapshot, catalog }, [snapshot, catalog]);
  useEffect(() => {
    window.React = React;
    window.cmuxAcpmuxRegistry = { register(kind, renderer, options) { const registered = window.cmuxAcpmuxRegistry as unknown as Record<string, unknown>; if (registered[kind] === renderer && (!options?.measure || options.measure === renderer.measure)) return; if (options?.measure) renderer.measure = options.measure; registered[kind] = renderer; setRegistry(currentRegistry()); }, configure() { setRegistry(currentRegistry()); } };
    window.cmuxAcpmuxBridge = {
      receive(next) { if (next.protocolVersion !== 1) return; const change = diffRows(rowsRef.current, next.rows); rowsRef.current = new Map(next.rows.map((row) => [row.id, row])); setSnapshot(next); void change; },
      applyTheme(theme) { applyAgentTheme(theme as never); },
      toggleInspector(open) { const next = typeof open === "boolean" ? open : !inspectorOpenRef.current; inspectorOpenRef.current = next; setInspectorOpen(next); return next; },
      applyCustomization(customization) { if ("themeCSS" in customization) { let style = document.getElementById("acpmux-user-theme") as HTMLStyleElement | null; if (!style) { style = document.createElement("style"); style.id = "acpmux-user-theme"; document.head.append(style); } style.textContent = customization.themeCSS ?? ""; } if (customization.registryJS) { try { (0, eval)(customization.registryJS); setRegistry(currentRegistry()); } catch { /* a user renderer must not take down the transcript */ } } if (customization.layout) window.cmuxAcpmuxRegistry?.configure(customization.layout); },
    };
    window.cmuxAcpmuxDebug = createAcpmuxDebug({
      replaceRows(rows) {
        rowsRef.current = new Map(rows.map((row) => [row.id, row]));
        setSnapshot((current) => ({ ...current, rows, connection: "debug", isWorking: false, canLoadOlder: false }));
      },
      rowCount: () => rowsRef.current.size,
      sessionId: () => directClient.current?.selectedSession,
    });
    let cancelled = false;
    let retryTimer: number | undefined;
    let retryDelay = 250;
    // Once a daemon was lost, handshakes only look for one: the user may have stopped it.
    // Looking is cheap, so a daemon started again elsewhere is found within seconds.
    const RECONNECT_MAX_DELAY_MS = 2_000;
    let reconnect = false;
    const connectHost = async () => {
      try {
        acpWire.lifecycle("handshake", { reconnect });
        const host = await callNative<{ protocolVersion: number; transport?: string; endpoint?: string; token?: string; sessionId?: string; newSession?: boolean }>("ready", reconnect ? { reconnect } : {});
        if (cancelled) return;
        if (host.transport === "mock") {
          window.cmuxAcpmuxActions = startMockHost((next) => { rowsRef.current = new Map(next.rows.map((row) => [row.id, row])); setSnapshot(next); });
          return;
        }
        if (host.transport !== "acpmux-websocket" || !host.endpoint || !host.token) return;
        const client = await AcpmuxDirectClient.connect(host as AcpmuxHostConfig, (next) => {
          rowsRef.current = new Map(next.rows.map((row) => [row.id, row]));
          setSnapshot(next);
        }, () => {
          // The daemon went away. Ask Swift again: a restarted daemon has a new port and token.
          if (cancelled) return;
          reconnect = true;
          directClient.current = undefined;
          delete window.cmuxAcpmuxActions;
          retryTimer = window.setTimeout(() => void connectHost(), retryDelay);
          retryDelay = Math.min(retryDelay * 2, reconnect ? RECONNECT_MAX_DELAY_MS : 30_000);
        });
        if (cancelled) { client.close(); return; }
        directClient.current = client;
        catalogClientId.current += 1;
        setCatalogSource({ id: catalogClientId.current, client });
        retryDelay = 250;
        const persistSession = (sessionId?: string) => sessionId ? callNative("chat.persistSession", { sessionId }).catch(() => undefined) : Promise.resolve();
        window.cmuxAcpmuxActions = {
          "chat.send": async ({ text }) => { const sessionId = await client.ensureSession(); await persistSession(sessionId); return client.send(String(text ?? "")); },
          "chat.cancel": () => client.cancel(),
          "chat.permission": ({ permissionId, optionId }) => client.permission(String(permissionId), String(optionId)),
          "chat.model": ({ modelId }) => client.setModel(String(modelId)),
          "chat.mode": ({ modeId }) => client.setMode(String(modeId)),
          "chat.effort": ({ configId, value }) => client.setConfig(String(configId), String(value)),
          "chat.select": async ({ sessionId }) => persistSession(await client.select(String(sessionId))),
          "chat.new": async ({ harness }) => persistSession(await client.create(harness ? String(harness) : undefined)),
          "chat.history": () => client.loadOlder(),
        };
        client.snapshot();
      } catch (error) {
        if (!cancelled) {
          acpWire.lifecycle("handshake failed", { message: String(error) });
          setSnapshot((current) => ({ ...current, connection: `connecting: ${String(error)}` }));
          // Back off so a host without a daemon is not asked four times a second.
          retryTimer = window.setTimeout(() => void connectHost(), retryDelay);
          retryDelay = Math.min(retryDelay * 2, reconnect ? RECONNECT_MAX_DELAY_MS : 30_000);
        }
      }
    };
    void connectHost();
    return () => { cancelled = true; if (retryTimer !== undefined) window.clearTimeout(retryTimer); directClient.current?.close(); directClient.current = undefined; delete window.cmuxAcpmuxActions; };
  }, []);
  const sessionEvents = useCallback(() => directClient.current?.sessionEvents() ?? [], []);
  const closeInspector = useCallback(() => setInspectorOpen(false), []);
  const send = (event: React.FormEvent<HTMLFormElement>) => { event.preventDefault(); const form = event.currentTarget; const textarea = form.elements.namedItem("prompt") as HTMLTextAreaElement; const text = textarea.value.trim(); if (!text) return; textarea.value = ""; void callNative("chat.send", { text }); };
  const ComposerChips = ((window.cmuxAcpmuxRegistry as unknown as Record<string, unknown> | undefined)?.composerChips as React.ComponentType<{ snapshot: AcpmuxSnapshot }> | undefined) ?? DefaultComposerChips;
  const sidebarShown = sidebar === "open" || (sidebar === "auto" && wide);
  const toggleSidebar = () => setSidebar(sidebarShown ? "closed" : "open");
  // The catalog arrives through the query cache, which composerSnapshot carries.
  const header = paneHeader(composerSnapshot);
  return <section className="acpmux-shell" data-sidebar={sidebar}><SessionSidebar sessions={snapshot.sessions} selectedId={snapshot.sessionId} onSelect={selectSession} />{sidebar === "open" && <button type="button" className="acpmux-sidebar-scrim" aria-label="Close sessions" tabIndex={-1} onClick={closeOverlay} />}<div className="acpmux-main"><div className={`acpmux-stage${diffFiles ? " acpmux-reviewing" : ""}`}><header className="acpmux-header"><div><button type="button" className="acpmux-sidebar-toggle" ref={sidebarToggle} aria-label="Sessions" title="Sessions" aria-controls="acpmux-sidebar" aria-expanded={sidebarShown} onClick={toggleSidebar} /><strong className="acpmux-title">{header.title}</strong>{header.status && <span className="acpmux-status">{header.status}</span>}</div><InspectorToggle open={inspectorOpen} onToggle={() => setInspectorOpen((open) => !open)} /></header><VirtualTranscript rows={snapshot.rows} canLoadOlder={snapshot.canLoadOlder} expanded={expanded} registry={registry} onOpenDiff={openDiff} onToggleActivity={(id) => setExpanded((current) => { const next = new Set(current); if (next.has(id)) next.delete(id); else next.add(id); return next; })} />{diffView && diffFiles && <DiffPanel files={diffFiles} initialPath={diffView.path} onClose={closeDiff} />}{inspectorOpen && <Inspector snapshot={snapshot} sessionEvents={sessionEvents} onClose={closeInspector} onExport={saveLogNatively} />}</div>{snapshot.queue.length > 0 && <div className="acpmux-queue">{snapshot.queue.map((entry) => <span className="acpmux-queued" key={entry.id}>Queued: {entry.prompt}</span>)}</div>}{snapshot.permission?.pending && <div className="acpmux-permission"><PermissionCard permission={snapshot.permission} /></div>}<form className="acpmux-composer" onSubmit={send}><ComposerChips snapshot={composerSnapshot} /><textarea aria-label="Prompt" name="prompt" rows={2} placeholder="Ask anything" /><button type="submit">Send</button>{snapshot.isWorking && <button type="button" className="acpmux-cancel" onClick={() => void callNative("chat.cancel")}>Stop</button>}</form></div></section>;
}

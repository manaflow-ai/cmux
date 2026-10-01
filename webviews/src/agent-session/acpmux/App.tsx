import React, { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import type { Token } from "marked";
import { applyAgentTheme } from "../shared/theme";
import { diffRows, layoutConversation, markdownBlocks, safeHref, transcriptRowWidth, visibleLayoutRange, type AcpmuxPermission, type AcpmuxRow, type AcpmuxSnapshot } from "./model";
import { AcpmuxDirectClient, type AcpmuxHostConfig } from "./direct";
import { startMockHost } from "./mock";
import { createAcpmuxDebug, type AcpmuxDebug } from "./debug";
import { acpmuxPerf } from "./perf";
import { ScrollPacing } from "./pacing";

type Reply<T> = { ok: true; value: T } | { ok: false; error?: { userMessage?: string } };
type MeasurableRenderer = React.ComponentType<RowProps> & { measure?: (row: AcpmuxRow, width: number) => number };
type NativeRegistry = Record<string, MeasurableRenderer>;
type RowProps = { row: AcpmuxRow; onToggleActivity: (id: string) => void; expanded: boolean };

declare global {
  interface Window {
    cmuxAcpmuxBridge?: {
      receive(snapshot: AcpmuxSnapshot): void;
      applyTheme(theme: Record<string, unknown>): void;
      applyCustomization(customization: { themeCSS?: string; registryJS?: string; layout?: Record<string, unknown> }): void;
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

function MarkdownBlocks({ source }: { source: string }) {
  return <>{markdownBlocks(source).map((token, index) => {
    if (token.type === "code") return <pre key={index}><code>{token.text}</code></pre>;
    if (token.type === "heading") return <div className={`acpmux-heading acpmux-heading-${token.depth}`} key={index}>{renderInline(token.tokens, token.text)}</div>;
    if (token.type === "paragraph" || token.type === "text") return <p key={index}>{renderInline(token.tokens, token.text)}</p>;
    if (token.type === "list") return <ul key={index}>{token.items.map((item, itemIndex) => <li key={itemIndex}>{renderInline(item.tokens, item.text)}</li>)}</ul>;
    if (token.type === "blockquote") return <blockquote key={index}>{renderInline(token.tokens, token.text)}</blockquote>;
    if (token.type === "hr") return <hr key={index} />;
    return <p key={index}>{token.raw}</p>;
  })}</>;
}

const MessageRow = memo(function MessageRow({ row }: RowProps) {
  return <div className={`acpmux-markdown ${row.kind === "user" ? "acpmux-user-bubble" : ""}`}><MarkdownBlocks source={row.text ?? ""} /></div>;
}, (previous, next) => previous.row.id === next.row.id && previous.row.version === next.row.version);

const ToolActivityRow = memo(function ToolActivityRow({ row, onToggleActivity, expanded }: RowProps) {
  return <div className="acpmux-activity"><button className="acpmux-activity-toggle" aria-expanded={expanded} onClick={() => onToggleActivity(row.id)}>{expanded ? "⌄" : "›"} Worked with {row.toolCount ?? 0} tool calls</button>{expanded && <div className="acpmux-activity-items">{(row.items ?? []).map((item) => <div className="acpmux-activity-item" key={`${row.id}-${item.text}`}><span className="acpmux-glyph">{item.kind === "tool" ? "▣" : "✦"}</span>{item.text}{item.tool?.output && <pre>{item.tool.output}</pre>}</div>)}</div>}</div>;
}, (previous, next) => previous.row.id === next.row.id && previous.row.version === next.row.version && previous.expanded === next.expanded);

const SummaryRow = memo(function SummaryRow({ row }: RowProps) { return <div className="acpmux-summary">{`Worked for ${Math.round((row.durationMs ?? 0) / 1000)}s · ${row.toolCount ?? 0} tool calls`}</div>; }, (a, b) => a.row.id === b.row.id && a.row.version === b.row.version);
const NoticeRow = memo(function NoticeRow({ row }: RowProps) { return <div className="acpmux-muted">{row.text}</div>; }, (a, b) => a.row.id === b.row.id && a.row.version === b.row.version);
const PermissionRow = memo(function PermissionRow({ row }: RowProps) { const permission = row.permission; return <div className="acpmux-permission-card"><strong>{permission?.title || "Permission required"}</strong><div className="acpmux-permission-buttons">{permission?.options.map((option) => <button key={option.id} onClick={() => void callNative("chat.permission", { permissionId: permission.permissionId, optionId: option.id })}>{option.name}</button>)}</div></div>; }, (a, b) => a.row.id === b.row.id && a.row.version === b.row.version);
const EditedFilesRow = memo(function EditedFilesRow({ row }: RowProps) { const files = (row.items ?? []).filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange"); return <div className="acpmux-edited-files"><strong>Edited files</strong>{files.map((file) => <div key={file.tool?.id || file.text}>▤ {file.tool?.inputSummary || file.text}</div>)}</div>; }, (a, b) => a.row.id === b.row.id && a.row.version === b.row.version);

const defaultRegistry: NativeRegistry = { user: MessageRow, assistant: MessageRow, activity: ToolActivityRow, editedFiles: EditedFilesRow, turnSummary: SummaryRow, notice: NoticeRow, plan: NoticeRow, typing: NoticeRow, permission: PermissionRow };

function MeasuredCustomRow({ children, onHeight }: { children: React.ReactNode; onHeight: (height: number) => void }) {
  const ref = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    const report = () => onHeight(node.getBoundingClientRect().height);
    const observer = new ResizeObserver(report);
    observer.observe(node);
    report();
    return () => observer.disconnect();
  }, [onHeight]);
  return <div ref={ref as React.RefObject<HTMLDivElement>}>{children}</div>;
}

/// Who spoke, for assistive technology: each article is one message in the transcript feed.
const speaker = (kind: string) => kind === "user" ? "You" : kind === "assistant" ? "Agent" : undefined;
const rowKind = (row: AcpmuxRow) => row.kind === "activity" && row.items?.some((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange") ? "editedFiles" : row.kind;
const currentRegistry = (): NativeRegistry => ({ ...defaultRegistry, ...(window.cmuxAcpmuxRegistry as unknown as NativeRegistry | undefined) });

/// Scroll steps of rows mounted ahead in the scroll direction, capped in viewports.
/// A scroll commits from its event, a frame after the offset moved, so without the
/// lead a fling shows a blank edge on every frame.
const SCROLL_LEAD_STEPS = 2;
const MAX_SCROLL_LEAD_VIEWPORTS = 4;

export function VirtualTranscript({ rows, onToggleActivity, expanded, registry = defaultRegistry, canLoadOlder = false }: { rows: AcpmuxRow[]; onToggleActivity: (id: string) => void; expanded: Set<string>; registry?: NativeRegistry; canLoadOlder?: boolean }) {
  // Debug measurement (acpmuxPerf): off until the first debug call.
  const renderStart = acpmuxPerf.enabled ? performance.now() : 0;
  const [scroll, setScroll] = useState({ top: 0, delta: 0 });
  const [height, setHeight] = useState(600);
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(760);
  const [measuredHeights, setMeasuredHeights] = useState(new Map<string, number>());
  const didOpenAtLatest = useRef(false);
  const measurementCache = useRef(new Map<string, import("./model").PreparedRow>());
  useEffect(() => { const node = ref.current; if (!node) return; const observer = new ResizeObserver(() => { setHeight(node.clientHeight); setWidth(node.clientWidth); }); observer.observe(node); setWidth(node.clientWidth); return () => observer.disconnect(); }, []);
  const previousLayout = useRef<ReturnType<typeof layoutConversation> | null>(null);
  // Scroll frames re-render with the same rows; only rows, width, measured custom
  // heights or the registry can move a row.
  const measured = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    const layout = layoutConversation(rows, transcriptRowWidth(width), measurementCache.current, (row, rowWidth) => registry[rowKind(row)]?.measure?.(row, rowWidth) ?? measuredHeights.get(row.id));
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
  }, [rows, width, measuredHeights, registry]);
  const layout = measured.layout;
  const reportedLayout = useRef<typeof measured | null>(null);
  const lead = Math.min(Math.abs(scroll.delta) * SCROLL_LEAD_STEPS, height * MAX_SCROLL_LEAD_VIEWPORTS);
  const range = visibleLayoutRange(layout, scroll.delta < 0 ? scroll.top - lead : scroll.top, height + lead);
  useLayoutEffect(() => {
    const last = range.last - 1;
    acpmuxPerf.mountedTop = range.last > range.first ? layout.tops[range.first] : 0;
    acpmuxPerf.mountedBottom = range.last > range.first ? layout.tops[last] + layout.heights[last] : 0;
    // A memo hit spent no time in geometry this render.
    const freshLayout = reportedLayout.current !== measured;
    reportedLayout.current = measured;
    const layoutMs = freshLayout ? measured.ms : 0;
    if (acpmuxPerf.enabled && freshLayout) acpmuxPerf.addLayout(layoutMs);
    if (acpmuxPerf.enabled && renderStart > 0) { const now = performance.now(); acpmuxPerf.commit(now - renderStart, layoutMs, acpmuxPerf.mountedTop, acpmuxPerf.mountedBottom, now); }
  });
  useLayoutEffect(() => {
    const old = previousLayout.current;
    const node = ref.current;
    if (old && node && old.tops.length === layout.tops.length && range.first > 0) {
      const delta = layout.tops[range.first] - old.tops[range.first];
      if (Math.abs(delta) > 0.5) node.scrollTop += delta;
    }
    // Runs on height too: rows that fit and then overflow on a height-only shrink keep the same memoized layout.
    if (!didOpenAtLatest.current && node && layout.totalHeight > node.clientHeight) {
      const latest = Math.max(0, layout.totalHeight - node.clientHeight);
      node.scrollTop = latest;
      setScroll({ top: latest, delta: 0 });
      didOpenAtLatest.current = true;
    }
    previousLayout.current = layout;
  }, [layout, range.first, height]);
  // Commit before this frame paints; deferring to the next animation frame left the edge blank.
  // Each settled scroll's frame pacing goes to the host, which picks the pane's rendering rate.
  const pacing = useMemo(() => new ScrollPacing((intervals) => { callNative("pane.framePacing", { intervals }).catch(() => {}); }), []);
  useEffect(() => () => pacing.stop(), [pacing]);
  const onScroll = (event: React.UIEvent<HTMLDivElement>) => { pacing.scrolled(); const next = event.currentTarget.scrollTop; flushSync(() => setScroll((current) => ({ top: next, delta: next - current.top }))); };
  return <div ref={ref} className="acpmux-scroll" role="feed" aria-label="Transcript" onScroll={onScroll}><div className="acpmux-spacer" style={{ height: layout.totalHeight }}><div className="acpmux-thread">{rows.slice(range.first, range.last).map((row, index) => { const absoluteIndex = range.first + index; const kind = rowKind(row); const Component = registry[kind] ?? NoticeRow; const rendered = <Component row={row} onToggleActivity={onToggleActivity} expanded={expanded.has(row.id)} />; return <article className={`acpmux-row acpmux-${kind}`} aria-label={speaker(kind)} aria-posinset={absoluteIndex + 1} aria-setsize={canLoadOlder ? -1 : rows.length} style={{ transform: `translateY(${layout.tops[absoluteIndex]}px)` }} key={row.id}>{Component.measure || defaultRegistry[kind] ? rendered : <MeasuredCustomRow onHeight={(value) => setMeasuredHeights((current) => { if (current.get(row.id) === value) return current; const next = new Map(current); next.set(row.id, value); return next; })}>{rendered}</MeasuredCustomRow>}</article>; })}</div></div></div>;
}

function PermissionCard({ permission }: { permission: AcpmuxPermission }) { return <div className="acpmux-permission-card"><strong>{permission.title || "Permission required"}</strong><div className="acpmux-permission-buttons">{permission.options.map((option) => <button key={option.id} onClick={() => void callNative("chat.permission", { permissionId: permission.permissionId, optionId: option.id })}>{option.name}</button>)}</div></div>; }

function DefaultComposerChips({ snapshot }: { snapshot: AcpmuxSnapshot }) { const modelOptions = snapshot.catalog.find((harness) => harness.id === snapshot.summary?.harness)?.models ?? []; const modeOptions = snapshot.summary?.modes?.availableModes ?? []; const effort = snapshot.summary?.configOptions?.find((option) => option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort"); return <div className="acpmux-chips"><select className="acpmux-model" aria-label="Model" value={snapshot.summary?.model ?? ""} onChange={(event) => void callNative("chat.model", { modelId: event.target.value })}>{modelOptions.map((model) => <option key={model.id} value={model.id}>{model.name || model.id}</option>)}</select><select className="acpmux-mode" aria-label="Mode" value={snapshot.summary?.modes?.currentModeId ?? ""} onChange={(event) => void callNative("chat.mode", { modeId: event.target.value })}>{modeOptions.map((mode) => <option key={mode.id} value={mode.id}>{mode.name || mode.id}</option>)}</select>{effort && <select className="acpmux-effort" aria-label="Effort" value={effort.currentValue ?? ""} onChange={(event) => void callNative("chat.effort", { configId: effort.id, value: event.target.value })}>{effort.options.map((option) => <option key={option.value} value={option.value}>{option.name || option.value}</option>)}</select>}</div>; }

export function AcpmuxApp() {
  const [snapshot, setSnapshot] = useState<AcpmuxSnapshot>({ type: "snapshot", protocolVersion: 1, rows: [], sessions: [], connection: "connecting", isWorking: false, queue: [], catalog: [], canLoadOlder: false });
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [registry, setRegistry] = useState<NativeRegistry>(defaultRegistry);
  const rowsRef = useRef(new Map<string, AcpmuxRow>());
  const directClient = useRef<AcpmuxDirectClient | undefined>(undefined);
  useEffect(() => {
    window.React = React;
    window.cmuxAcpmuxRegistry = { register(kind, renderer, options) { const registered = window.cmuxAcpmuxRegistry as unknown as Record<string, unknown>; if (registered[kind] === renderer && (!options?.measure || options.measure === renderer.measure)) return; if (options?.measure) renderer.measure = options.measure; registered[kind] = renderer; setRegistry(currentRegistry()); }, configure() { setRegistry(currentRegistry()); } };
    window.cmuxAcpmuxBridge = {
      receive(next) { if (next.protocolVersion !== 1) return; const change = diffRows(rowsRef.current, next.rows); rowsRef.current = new Map(next.rows.map((row) => [row.id, row])); setSnapshot(next); void change; },
      applyTheme(theme) { applyAgentTheme(theme as never); },
      applyCustomization(customization) { if ("themeCSS" in customization) { let style = document.getElementById("acpmux-user-theme") as HTMLStyleElement | null; if (!style) { style = document.createElement("style"); style.id = "acpmux-user-theme"; document.head.append(style); } style.textContent = customization.themeCSS ?? ""; } if (customization.registryJS) { try { (0, eval)(customization.registryJS); setRegistry(currentRegistry()); } catch { /* a user renderer must not take down the transcript */ } } if (customization.layout) window.cmuxAcpmuxRegistry?.configure(customization.layout); },
    };
    window.cmuxAcpmuxDebug = createAcpmuxDebug({
      replaceRows(rows) {
        rowsRef.current = new Map(rows.map((row) => [row.id, row]));
        setSnapshot((current) => ({ ...current, rows, connection: "debug", isWorking: false, canLoadOlder: false }));
      },
      rowCount: () => rowsRef.current.size,
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
  const send = (event: React.FormEvent<HTMLFormElement>) => { event.preventDefault(); const form = event.currentTarget; const textarea = form.elements.namedItem("prompt") as HTMLTextAreaElement; const text = textarea.value.trim(); if (!text) return; textarea.value = ""; void callNative("chat.send", { text }); };
  const ComposerChips = ((window.cmuxAcpmuxRegistry as unknown as Record<string, unknown> | undefined)?.composerChips as React.ComponentType<{ snapshot: AcpmuxSnapshot }> | undefined) ?? DefaultComposerChips;
  return <section className="acpmux-shell"><header className="acpmux-header"><div><strong className="acpmux-title">{snapshot.summary?.title || snapshot.summary?.name || "Agent Chat"}</strong><span className="acpmux-status">{snapshot.isWorking ? "Working" : snapshot.connection}</span></div><select className="acpmux-session" value={snapshot.sessionId ?? ""} onChange={(event) => void callNative("chat.select", { sessionId: event.target.value })}>{snapshot.sessions.map((session) => <option key={session.sessionId} value={session.sessionId}>{session.title || session.name || session.sessionId.slice(0, 8)}</option>)}</select></header><VirtualTranscript rows={snapshot.rows} canLoadOlder={snapshot.canLoadOlder} expanded={expanded} registry={registry} onToggleActivity={(id) => setExpanded((current) => { const next = new Set(current); if (next.has(id)) next.delete(id); else next.add(id); return next; })} />{snapshot.queue.length > 0 && <div className="acpmux-queue">{snapshot.queue.map((entry) => <span className="acpmux-queued" key={entry.id}>Queued: {entry.prompt}</span>)}</div>}{snapshot.permission?.pending && <div className="acpmux-permission"><PermissionCard permission={snapshot.permission} /></div>}<form className="acpmux-composer" onSubmit={send}><ComposerChips snapshot={snapshot} /><textarea aria-label="Prompt" name="prompt" rows={2} placeholder="Ask anything" /><button type="submit">Send</button><button type="button" className="acpmux-cancel" onClick={() => void callNative("chat.cancel")}>Stop</button></form></section>;
}

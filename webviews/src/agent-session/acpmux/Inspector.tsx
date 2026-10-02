// The ACP inspector: what this pane sent to and received from acpmux (the
// wire log, wire.ts) and the selected session's ACP event journal as acpmux
// recorded it, with the connection and session state above them. It opens
// over the transcript like the diff panel and reads nothing while closed.
import React, { useEffect, useState } from "react";
import type { EventRecord } from "./direct";
import type { AcpmuxSnapshot } from "./model";
import { acpWire, type AcpWireLog, type WireEntry } from "./wire";

/** Rows rendered per view; the newest are kept. */
export const SHOWN_ROWS = 500;

export type InspectorView = "wire" | "session";

/** What the host did with an export: saved it, the user cancelled its save panel, or it cannot save (the log is copied instead). */
export type ExportOutcome = "saved" | "cancelled" | "unavailable";

/** `acp-<session8>-<yyyyMMdd-HHmmss>.jsonl` in local time; `acp-<time>.jsonl` without a session. */
export function exportFileName(sessionId: string | undefined, at: Date): string {
  const pad = (value: number) => String(value).padStart(2, "0");
  const stamp = `${at.getFullYear()}${pad(at.getMonth() + 1)}${pad(at.getDate())}-${pad(at.getHours())}${pad(at.getMinutes())}${pad(at.getSeconds())}`;
  return ["acp", sessionId?.slice(0, 8), stamp].filter(Boolean).join("-") + ".jsonl";
}

export type InspectorRow = { key: string; at: number; dir: string; kind: string; name: string; latencyMs?: number; size?: number; body: string };

/** HH:MM:SS.mmm in local time. */
export function clockTime(at: number): string {
  const date = new Date(at);
  const pad = (value: number, width = 2) => String(value).padStart(width, "0");
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(date.getMilliseconds(), 3)}`;
}

function pretty(text: string | undefined, fallback: unknown): string {
  if (text !== undefined) {
    try { return JSON.stringify(JSON.parse(text), null, 2); } catch { return text; }
  }
  return fallback === undefined ? "" : JSON.stringify(fallback, null, 2);
}

export function wireRow(entry: WireEntry): InspectorRow {
  const name = entry.kind === "lifecycle" ? entry.event ?? "" : [entry.method, entry.id !== undefined ? `#${entry.id}` : undefined].filter(Boolean).join(" ");
  const body = pretty(entry.text, entry.detail) + (entry.truncated ? `\n… cut at ${entry.text?.length} of ${entry.size} characters` : "");
  return { key: `w${entry.seq}`, at: entry.at, dir: entry.dir, kind: entry.kind, name, latencyMs: entry.latencyMs, size: entry.size, body };
}

export function sessionRow(event: EventRecord): InspectorRow {
  const method = typeof event.msg?.method === "string" ? event.msg.method : undefined;
  const update = event.msg?.params?.update?.sessionUpdate;
  const name = [method, typeof update === "string" ? update : undefined].filter(Boolean).join(" ") || event.kind;
  return { key: `s${event.seq}`, at: event.at, dir: event.dir, kind: event.kind, name: `${name} · seq ${event.seq}`, body: JSON.stringify(event.msg, null, 2) };
}

/** The newest `SHOWN_ROWS` rows whose name, kind or body contains `filter` (case-insensitive). */
export function visibleRows(rows: InspectorRow[], filter: string): InspectorRow[] {
  const needle = filter.trim().toLowerCase();
  const matching = needle ? rows.filter((row) => row.name.toLowerCase().includes(needle) || row.kind.includes(needle) || row.body.toLowerCase().includes(needle)) : rows;
  return matching.slice(-SHOWN_ROWS);
}

/** Re-reads the wire log at most once per frame while the inspector is open. */
function useWireEntries(wire: AcpWireLog): WireEntry[] {
  const [entries, setEntries] = useState(() => wire.entries());
  useEffect(() => {
    let frame: number | undefined;
    const unsubscribe = wire.subscribe(() => {
      if (frame !== undefined) return;
      frame = requestAnimationFrame(() => { frame = undefined; setEntries(wire.entries()); });
    });
    setEntries(wire.entries());
    return () => { unsubscribe(); if (frame !== undefined) cancelAnimationFrame(frame); };
  }, [wire]);
  return entries;
}

function copyText(text: string): boolean {
  const area = document.createElement("textarea");
  area.value = text;
  area.setAttribute("readonly", "");
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.append(area);
  area.select();
  let copied = false;
  try { copied = document.execCommand("copy"); } catch { copied = false; }
  area.remove();
  return copied;
}

const DIR_GLYPH: Record<string, string> = { out: "→", in: "←", local: "•" };

export function Inspector({ snapshot, sessionEvents, onClose, onExport, wire = acpWire }: {
  snapshot: AcpmuxSnapshot;
  /** The selected session's ACP events as the client holds them. */
  sessionEvents: () => EventRecord[];
  onClose: () => void;
  /** Saves the exported log under a suggested file name. Without it, or when it resolves (or fails) as unavailable, the log is copied instead. */
  onExport?: (text: string, suggestedName: string) => Promise<ExportOutcome>;
  wire?: AcpWireLog;
}) {
  const [view, setView] = useState<InspectorView>("wire");
  const [filter, setFilter] = useState("");
  const [open, setOpen] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const entries = useWireEntries(wire);
  const stats = wire.stats();
  // The client's journal grows with each snapshot, which renders this again.
  const events = view === "session" ? sessionEvents() : [];
  const rows = visibleRows(view === "wire" ? entries.map(wireRow) : events.map(sessionRow), filter);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const exportLog = async () => {
    const text = wire.exportJsonl({ sessionId: snapshot.sessionId, connection: snapshot.connection, sessionStatus: snapshot.summary?.status });
    const outcome = onExport ? await onExport(text, exportFileName(snapshot.sessionId, new Date())).catch((): ExportOutcome => "unavailable") : "unavailable";
    // A cancelled save panel was the user's choice: nothing is copied.
    if (outcome === "saved") setNotice("Saved");
    else if (outcome === "cancelled") setNotice(undefined);
    else setNotice(copyText(text) ? "Copied as JSON Lines" : "Could not copy");
  };

  return <section className="acpmux-inspector" aria-label="ACP inspector">
    <div className="acpmux-diff-header">
      <button type="button" className="acpmux-diff-back" aria-label="Back" onClick={onClose}>‹</button>
      <strong>ACP Inspector</strong>
      <div className="acpmux-diff-layout" aria-label="View">
        <button type="button" aria-pressed={view === "wire"} onClick={() => setView("wire")}>Wire</button>
        <button type="button" aria-pressed={view === "session"} onClick={() => setView("session")}>Session</button>
      </div>
    </div>
    <dl className="acpmux-inspector-state">
      <div><dt>Connection</dt><dd>{snapshot.connection}</dd></div>
      <div><dt>Session</dt><dd title={snapshot.sessionId}>{snapshot.sessionId ? `${snapshot.sessionId.slice(0, 8)} · ${snapshot.summary?.status ?? "unknown"}` : "none"}</dd></div>
      <div><dt>Requests</dt><dd>{stats.requests}{stats.inFlight ? ` · ${stats.inFlight} in flight` : ""}</dd></div>
      <div><dt>Latency</dt><dd>{stats.latencyP50Ms === undefined ? "–" : `p50 ${Math.round(stats.latencyP50Ms)} ms · max ${Math.round(stats.latencyMaxMs ?? 0)} ms`}</dd></div>
      <div><dt>Errors</dt><dd>{stats.errors}</dd></div>
      <div><dt>Reconnects</dt><dd>{stats.reconnects} · {stats.closes} closed</dd></div>
      {stats.lastError && <div className="acpmux-inspector-wide"><dt>Last error</dt><dd>{stats.lastError}</dd></div>}
    </dl>
    <div className="acpmux-inspector-tools">
      <input type="search" aria-label="Filter" placeholder="Filter" value={filter} onChange={(event) => setFilter(event.target.value)} />
      <span className="acpmux-inspector-count">{rows.length < (view === "wire" ? entries.length : events.length) ? `${rows.length} of ${view === "wire" ? entries.length : events.length}` : rows.length}{view === "wire" && stats.dropped ? ` · ${stats.dropped} older dropped` : ""}</span>
      {notice && <output className="acpmux-inspector-count">{notice}</output>}
      <button type="button" onClick={() => void exportLog()}>Export</button>
      {view === "wire" && <button type="button" onClick={() => { wire.clear(); setOpen(undefined); }}>Clear</button>}
    </div>
    <ol className="acpmux-inspector-list">
      {rows.map((row) => <li key={row.key} className={`acpmux-inspector-row acpmux-inspector-${row.kind}`}>
        <button type="button" aria-expanded={open === row.key} onClick={() => setOpen((current) => current === row.key ? undefined : row.key)}>
          <time>{clockTime(row.at)}</time>
          <span className="acpmux-inspector-dir" aria-label={row.dir}>{DIR_GLYPH[row.dir] ?? row.dir}</span>
          <span className="acpmux-inspector-kind">{row.kind}</span>
          <span className="acpmux-inspector-name">{row.name}</span>
          {row.latencyMs !== undefined && <span className="acpmux-inspector-num">{row.latencyMs < 10 ? row.latencyMs.toFixed(1) : Math.round(row.latencyMs)} ms</span>}
          {row.size !== undefined && <span className="acpmux-inspector-num">{row.size < 1024 ? `${row.size} B` : `${(row.size / 1024).toFixed(1)} KB`}</span>}
        </button>
        {open === row.key && <pre>{row.body}</pre>}
      </li>)}
    </ol>
  </section>;
}

/** The header button that opens the inspector: a quiet 28×28 icon. */
export function InspectorToggle({ open, onToggle }: { open: boolean; onToggle: () => void }) {
  return <button type="button" className="acpmux-icon-button" aria-label="ACP inspector" title="ACP inspector" aria-pressed={open} onClick={onToggle}>
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round"><path d="M2.5 4.5h7M2.5 8h11M2.5 11.5h5" /><path d="M11.5 3l2 1.5-2 1.5" /></svg>
  </button>;
}

// The ACP inspector: what this pane sent to and received from acpmux (the
// wire log, wire.ts) and the selected session's ACP event journal as acpmux
// recorded it, with the connection and session state above them. It opens
// over the transcript like the diff panel and reads nothing while closed.
import React, { useEffect, useRef, useState } from "react";
import type { EventRecord } from "./direct";
import { useT, type Translate, translate } from "./i18n";
import type { AcpmuxSnapshot } from "./model";
import { acpWire, type AcpWireLog, type WireEntry } from "./wire";
import "./Inspector.css";

/** Rows rendered per view; the newest are kept. */
export const SHOWN_ROWS = 500;

export type InspectorView = "wire" | "session";

export type InspectorRow = {
  key: string;
  at: number;
  dir: string;
  kind: string;
  name: string;
  latencyMs?: number;
  size?: number;
  body: string;
};

/** HH:MM:SS.mmm in local time. */
export function clockTime(at: number): string {
  const date = new Date(at);
  const pad = (value: number, width = 2) => String(value).padStart(width, "0");
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(date.getMilliseconds(), 3)}`;
}

function pretty(text: string | undefined, fallback: unknown): string {
  if (text !== undefined) {
    try {
      return JSON.stringify(JSON.parse(text), null, 2);
    } catch {
      return text;
    }
  }
  return fallback === undefined ? "" : JSON.stringify(fallback, null, 2);
}

export function wireRow(entry: WireEntry, t: Translate = translate): InspectorRow {
  const name =
    entry.kind === "lifecycle"
      ? (entry.event ?? "")
      : [entry.method, entry.id !== undefined ? `#${entry.id}` : undefined].filter(Boolean).join(" ");
  const body =
    pretty(entry.text, entry.detail) +
    (entry.truncated
      ? `\n${t("inspector.truncated", { shown: entry.text?.length ?? 0, total: entry.size ?? 0 })}`
      : "");
  return {
    key: `w${entry.seq}`,
    at: entry.at,
    dir: entry.dir,
    kind: entry.kind,
    name,
    latencyMs: entry.latencyMs,
    size: entry.size,
    body,
  };
}

export function sessionRow(event: EventRecord, t: Translate = translate): InspectorRow {
  const method = typeof event.msg?.method === "string" ? event.msg.method : undefined;
  const update = event.msg?.params?.update?.sessionUpdate;
  const name = [method, typeof update === "string" ? update : undefined].filter(Boolean).join(" ") || event.kind;
  return {
    key: `s${event.seq}`,
    at: event.at,
    dir: event.dir,
    kind: event.kind,
    name: t("inspector.sequence", { name, seq: event.seq }),
    body: JSON.stringify(event.msg, null, 2),
  };
}

/** The newest `SHOWN_ROWS` rows whose name, kind or body contains `filter` (case-insensitive). */
export function visibleRows(rows: InspectorRow[], filter: string): InspectorRow[] {
  const needle = filter.trim().toLowerCase();
  const matching = needle
    ? rows.filter(
        (row) =>
          row.name.toLowerCase().includes(needle) ||
          row.kind.includes(needle) ||
          row.body.toLowerCase().includes(needle),
      )
    : rows;
  return matching.slice(-SHOWN_ROWS);
}

/** Re-reads the wire log at most once per frame while the inspector is open. */
function useWireEntries(wire: AcpWireLog): WireEntry[] {
  const [entries, setEntries] = useState(() => wire.entries());
  useEffect(() => {
    let frame: number | undefined;
    const unsubscribe = wire.subscribe(() => {
      if (frame !== undefined) return;
      frame = requestAnimationFrame(() => {
        frame = undefined;
        setEntries(wire.entries());
      });
    });
    setEntries(wire.entries());
    return () => {
      unsubscribe();
      if (frame !== undefined) cancelAnimationFrame(frame);
    };
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
  try {
    copied = document.execCommand("copy");
  } catch {
    copied = false;
  }
  area.remove();
  return copied;
}

const DIR_GLYPH: Record<string, string> = { out: "→", in: "←", local: "•" };

export function Inspector({
  snapshot,
  sessionEvents,
  onClose,
  onExport,
  wire = acpWire,
}: {
  snapshot: AcpmuxSnapshot;
  /** The selected session's ACP events as the client holds them. */
  sessionEvents: () => EventRecord[];
  onClose: () => void;
  /** Saves the exported log; resolves false when the host cannot, and the log is copied instead. */
  onExport?: (text: string) => Promise<boolean>;
  wire?: AcpWireLog;
}) {
  const t = useT();
  const [view, setView] = useState<InspectorView>("wire");
  const [filter, setFilter] = useState("");
  const [open, setOpen] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const entries = useWireEntries(wire);
  const stats = wire.stats();
  // The client's journal grows with each snapshot, which renders this again.
  const events = view === "session" ? sessionEvents() : [];
  const rows = visibleRows(
    view === "wire" ? entries.map((entry) => wireRow(entry, t)) : events.map((event) => sessionRow(event, t)),
    filter,
  );

  const firstControlRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    firstControlRef.current?.focus();
  }, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const exportLog = async () => {
    const text = wire.exportJsonl({
      sessionId: snapshot.sessionId,
      connection: snapshot.connection,
      sessionStatus: snapshot.summary?.status,
    });
    const saved = onExport ? await onExport(text).catch(() => false) : false;
    setNotice(saved ? t("inspector.saved") : copyText(text) ? t("inspector.copied") : t("inspector.copyFailed"));
  };

  return (
    <section className="acpmux-inspector" aria-label={t("inspector.title")}>
      <div className="acpmux-diff-header">
        <button
          ref={firstControlRef}
          type="button"
          className="acpmux-diff-back"
          aria-label={t("inspector.back")}
          onClick={onClose}
        >
          ‹
        </button>
        <strong>{t("inspector.title")}</strong>
        <div className="acpmux-diff-tools acpmux-inspector-views" aria-label={t("inspector.view")}>
          <button
            type="button"
            className="acpmux-diff-tool"
            aria-pressed={view === "wire"}
            onClick={() => setView("wire")}
          >
            {t("inspector.wire")}
          </button>
          <button
            type="button"
            className="acpmux-diff-tool"
            aria-pressed={view === "session"}
            onClick={() => setView("session")}
          >
            {t("inspector.session")}
          </button>
        </div>
      </div>
      <dl className="acpmux-inspector-state">
        <div>
          <dt>{t("inspector.connection")}</dt>
          <dd>{snapshot.connection}</dd>
        </div>
        <div>
          <dt>{t("inspector.session")}</dt>
          <dd title={snapshot.sessionId}>
            {snapshot.sessionId
              ? `${snapshot.sessionId.slice(0, 8)} · ${snapshot.summary?.status ?? t("inspector.unknown")}`
              : t("inspector.none")}
          </dd>
        </div>
        <div>
          <dt>{t("inspector.requests")}</dt>
          <dd>
            {stats.requests}
            {stats.inFlight ? ` · ${t("inspector.inFlight", { count: stats.inFlight })}` : ""}
          </dd>
        </div>
        <div>
          <dt>{t("inspector.latency")}</dt>
          <dd>
            {stats.latencyP50Ms === undefined
              ? "–"
              : t("inspector.latencyValue", {
                  p50: Math.round(stats.latencyP50Ms),
                  max: Math.round(stats.latencyMaxMs ?? 0),
                })}
          </dd>
        </div>
        <div>
          <dt>{t("inspector.errors")}</dt>
          <dd>{stats.errors}</dd>
        </div>
        <div>
          <dt>{t("inspector.reconnects")}</dt>
          <dd>{t("inspector.reconnectValue", { count: stats.reconnects, closed: stats.closes })}</dd>
        </div>
        {stats.lastError && (
          <div className="acpmux-inspector-wide">
            <dt>{t("inspector.lastError")}</dt>
            <dd>{stats.lastError}</dd>
          </div>
        )}
      </dl>
      <div className="acpmux-inspector-tools">
        <input
          type="search"
          aria-label={t("inspector.filter")}
          placeholder={t("inspector.filter")}
          value={filter}
          onChange={(event) => setFilter(event.target.value)}
        />
        <span className="acpmux-inspector-count">
          {rows.length < (view === "wire" ? entries.length : events.length)
            ? t("inspector.rowsOf", { shown: rows.length, total: view === "wire" ? entries.length : events.length })
            : rows.length}
          {view === "wire" && stats.dropped ? ` · ${t("inspector.olderDropped", { count: stats.dropped })}` : ""}
        </span>
        {notice && <output className="acpmux-inspector-count">{notice}</output>}
        <button type="button" onClick={() => void exportLog()}>
          {t("inspector.export")}
        </button>
        {view === "wire" && (
          <button
            type="button"
            onClick={() => {
              wire.clear();
              setOpen(undefined);
            }}
          >
            {t("inspector.clear")}
          </button>
        )}
      </div>
      <ol className="acpmux-inspector-list">
        {rows.map((row) => (
          <li key={row.key} className={`acpmux-inspector-row acpmux-inspector-${row.kind}`}>
            <button
              type="button"
              aria-expanded={open === row.key}
              onClick={() => setOpen((current) => (current === row.key ? undefined : row.key))}
            >
              <time>{clockTime(row.at)}</time>
              <span className="acpmux-inspector-dir" aria-label={row.dir}>
                {DIR_GLYPH[row.dir] ?? row.dir}
              </span>
              <span className="acpmux-inspector-kind">{row.kind}</span>
              <span className="acpmux-inspector-name">{row.name}</span>
              {row.latencyMs !== undefined && (
                <span className="acpmux-inspector-num">
                  {t("inspector.milliseconds", {
                    value: row.latencyMs < 10 ? row.latencyMs.toFixed(1) : Math.round(row.latencyMs),
                  })}
                </span>
              )}
              {row.size !== undefined && (
                <span className="acpmux-inspector-num">
                  {row.size < 1024
                    ? t("inspector.bytes", { value: row.size })
                    : t("inspector.kilobytes", { value: (row.size / 1024).toFixed(1) })}
                </span>
              )}
            </button>
            {open === row.key && <pre>{row.body}</pre>}
          </li>
        ))}
      </ol>
    </section>
  );
}

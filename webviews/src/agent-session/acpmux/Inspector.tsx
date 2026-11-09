// The ACP inspector: what this pane sent to and received from acpmux (the
// wire log, wire.ts) and the selected session's ACP event journal as acpmux
// recorded it, with the connection and session state above them. It opens
// over the transcript like the diff panel and reads nothing while closed.
import { useEffect, useRef, useState } from "react";
import type { EventRecord } from "./direct";
import { useT } from "./i18n";
import type { AcpmuxSnapshot } from "./model";
import { acpWire, type AcpWireLog, type WireEntry } from "./wire";
import { SlidingIndicator } from "../../ui/motion/SlidingIndicator";
import "./Inspector.css";
import { exportFileName, clockTime, wireRow, sessionRow, visibleRows } from "./inspectorModel";
export type InspectorView = "wire" | "session";

/** What the host did with an export: saved it, the user cancelled its save panel, or it cannot save (the log is copied instead). */
export type ExportOutcome = "saved" | "cancelled" | "unavailable";

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
  /** Saves the export; cancellation leaves the clipboard unchanged. */
  onExport?: (text: string, suggestedName: string) => Promise<ExportOutcome>;
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
    const outcome = onExport
      ? await onExport(text, exportFileName(snapshot.sessionId, new Date())).catch((): ExportOutcome => "unavailable")
      : "unavailable";
    if (outcome === "saved") setNotice(t("inspector.saved"));
    else if (outcome === "cancelled") setNotice(undefined);
    else setNotice(copyText(text) ? t("inspector.copied") : t("inspector.copyFailed"));
  };

  return (
    <section className="acpmux-inspector" data-enter="right" aria-label={t("inspector.title")}>
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
        <div className="acpmux-diff-tools acpmux-inspector-views ui-slide-host" aria-label={t("inspector.view")}>
          {/* The pressed plate travels between Wire and Session (ui/motion, transform only). */}
          <SlidingIndicator selected={view} look="plate" />
          <button
            type="button"
            className="acpmux-diff-tool ui-slide-item"
            aria-pressed={view === "wire"}
            onClick={() => setView("wire")}
          >
            {t("inspector.wire")}
          </button>
          <button
            type="button"
            className="acpmux-diff-tool ui-slide-item"
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
          <dd>
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

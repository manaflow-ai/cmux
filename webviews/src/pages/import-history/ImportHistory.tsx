import { useSyncExternalStore } from "react";
import { DialogButton } from "../../ui/DialogButton";
import type { Strings } from "../shared/i18n";
import { canImport, type HistoryRow, type ImportHistoryStore, type Origin } from "./model";

export type HistoryLayout = "list" | "cards" | "compact";
export interface ImportHistoryProps {
  store: ImportHistoryStore;
  strings: Strings;
  layout?: HistoryLayout;
}

/** The list is the shipped layout: all sources share one scan line, with no wizard or card grid. */
export function ImportHistory({ store, strings, layout = "list" }: ImportHistoryProps) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const t = strings.t;
  const busy = snapshot.phase === "importing" || snapshot.undoing;
  const detail = snapshot.error?.startsWith("cmux.") ? undefined : snapshot.error;
  return (
    <form
      className={`import-history layout-${layout}`}
      onSubmit={(event) => {
        event.preventDefault();
        if (snapshot.phase === "done") void store.finish(true);
        else void store.run();
      }}
    >
      <div className="history-scroll">
        <div className="history-content">
          <header>
            <h1>{t("history.title")}</h1>
            <p className="history-lead">{t("history.subtitle")}</p>
          </header>
          <output className="history-notice" aria-live="polite">
            {t(`history.state.${snapshot.phase}`)}
          </output>
          <div className="history-sources">
            {snapshot.rows.map((row) => (
              <SourceRow
                key={row.id}
                row={row}
                store={store}
                strings={strings}
                busy={busy || snapshot.phase === "detecting"}
              />
            ))}
            {!snapshot.rows.some((row) => row.id === "dot") && (
              <SourceRow
                key="dot"
                row={SAVED_DOT_ROW}
                title={t("history.savedDot")}
                store={store}
                strings={strings}
                busy={busy || snapshot.phase === "detecting"}
              />
            )}
          </div>
          {(snapshot.error || snapshot.phase === "error") && (
            <div className="history-error" role="alert">
              <p>
                {t("history.error")}
                {detail && <span className="history-error-detail">{detail}</span>}
              </p>
              {snapshot.error && !busy && (
                <button type="button" className="history-link" onClick={() => void store.retryDetection()}>
                  {t("history.retry")}
                </button>
              )}
            </div>
          )}
          <p className="history-safety">{t("history.safety")}</p>
        </div>
      </div>
      <footer className="history-footer">
        <DialogButton dialogKey={null} className="history-button" onClick={() => void store.finish(false)}>
          {t("history.skip")}
        </DialogButton>
        <div className="history-primary-actions">
          {snapshot.canUndo && (
            <DialogButton dialogKey={null} className="history-button" disabled={busy} onClick={() => void store.undo()}>
              {t("history.undo")}
            </DialogButton>
          )}
          {snapshot.phase === "done" ? (
            <DialogButton
              dialogKey="return"
              className="history-button is-primary"
              onClick={() => void store.finish(true)}
            >
              {t("history.done")}
            </DialogButton>
          ) : (
            <DialogButton
              dialogKey="return"
              type="submit"
              className="history-button is-primary"
              disabled={!canImport(snapshot)}
            >
              {t("history.import")}
            </DialogButton>
          )}
        </div>
      </footer>
    </form>
  );
}

/** New Computer's discontinued Dot has no detectable source: until its saved zip is picked, it is an
 * ordinary unchecked zip row (same checkbox column and Choose action), and picking replaces it with
 * the model's real `dot` row. */
const SAVED_DOT_ROW: HistoryRow = { id: "dot", kind: "zip", selected: false, phase: "idle" };

function SourceRow({
  row,
  title: titleOverride,
  store,
  strings,
  busy,
}: {
  row: HistoryRow;
  title?: string;
  store: ImportHistoryStore;
  strings: Strings;
  busy: boolean;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const t = strings.t;
  const title = titleOverride ?? t(`history.source.${row.id}`);
  const unavailable = row.kind === "local" && !row.source;
  const selected = row.kind === "text" ? Boolean(row.expanded) : row.selected;
  return (
    <section className={`history-source phase-${row.phase}`}>
      <div className="history-source-line">
        <div className="history-source-label">
          <input
            type="checkbox"
            id={`history-select-${row.id}`}
            aria-label={title}
            checked={selected}
            disabled={busy || unavailable || (row.kind === "zip" && !row.source)}
            onChange={(event) => {
              const checked = event.target.checked;
              store.select(row.id, checked);
              if (row.kind === "text" && Boolean(row.expanded) !== checked) store.expand(row.id);
            }}
          />
          {row.kind === "zip" ? (
            <button
              type="button"
              className="history-source-title"
              disabled={busy || Boolean(snapshot.picking)}
              onClick={() => void store.pickZip(row.id as "chatgpt" | "claude" | "dot")}
            >
              {title}
            </button>
          ) : (
            <label htmlFor={`history-select-${row.id}`}>{title}</label>
          )}
        </div>
        <div className="history-source-action">
          {row.kind === "local" && (
            <span className="history-muted">
              {t(
                snapshot.phase === "detecting"
                  ? "history.row.planning"
                  : row.source
                    ? "history.detected"
                    : "history.notFound",
              )}
            </span>
          )}
          {row.kind === "zip" && (
            <button
              type="button"
              className="history-link"
              disabled={busy || Boolean(snapshot.picking)}
              onClick={() => void store.pickZip(row.id as "chatgpt" | "claude" | "dot")}
              aria-label={strings.format("history.chooseFor", title)}
            >
              {t(snapshot.picking === row.id ? "history.choosing" : "history.choose")}
            </button>
          )}
        </div>
      </div>
      {row.name && <p className="history-file">{row.name}</p>}
      {row.kind === "text" && row.expanded && (
        <div className="history-paste">
          <p>{t("history.pasteHelp")}</p>
          <button
            type="button"
            className="history-button"
            disabled={busy}
            onClick={() => void store.copy(row.id as Origin, t("history.prompt"))}
          >
            {t(snapshot.copied === row.id ? "history.copied" : "history.copy")}
          </button>
          <label className="history-paste-label" htmlFor={`history-paste-${row.id}`}>
            {t("history.pasteLabel")}
          </label>
          <textarea
            id={`history-paste-${row.id}`}
            aria-label={t("history.pasteLabel")}
            value={row.text ?? ""}
            disabled={busy}
            rows={4}
            onChange={(event) => store.paste(row.id as Origin, event.target.value)}
          />
        </div>
      )}
      {row.report && (
        <p className="history-report">
          {strings.format(
            "history.counts",
            String(row.report.plan.new),
            String(row.report.plan.duplicate),
            String(row.report.plan.secrets),
          )}
        </p>
      )}
      {row.phase !== "idle" && (
        <output className="history-row-status">
          {t(`history.row.${row.phase}`)}
          {row.phase === "done" && row.report?.written !== undefined && (
            <span> · {strings.format("history.written", String(row.report.written))}</span>
          )}
        </output>
      )}
      {row.error && !row.error.startsWith("cmux.") && <p className="history-error-detail">{row.error}</p>}
    </section>
  );
}

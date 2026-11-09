// Session Info's Storage (storageSectionModel.ts): the space this Mac can get back, machine-wide. A
// summary line with the disk's meter and what is free of it, then the stale worktrees, each with a
// checkbox, the reason it can go and the disk it holds, the largest first; the worktrees acpmux keeps
// folded into one count line. The person checks rows, the button below reads what it would free ("Free 3 worktrees · 2.1 GB"), and one press (or Return in the list) frees them; the
// line "Freed 2.1 GB" takes the button's place. The gallery (StorageSection.gallery.tsx) compares the
// layouts; this ships its "summary" one.
//
// The report costs acpmux seconds of git and disk reads, so it is asked for only once the section is
// open, again after a free and on Refresh, never on a timer. A daemon (or host) that does not know the
// method hides the section. Every state change keeps the section's footprint: the rows stay drawn while
// a new report comes, the summary line says "Measuring…" in place (after 300 ms, so a quick answer
// never flashes it), freed rows leave in the commit the answer lands in, and the rows below close up.
import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from "react";
import { Button } from "../../../ui/Button";
import { useAfterDelay } from "../afterDelay";
import { usePaneLanguage, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { SessionInfoFold } from "./SessionInfoSection";
import { useFoldMotion } from "./foldMotion";
import {
  afterClean,
  groupedRows,
  keptSelection,
  parseStorageReport,
  previewLabel,
  storageBytes,
  storageFailure,
  storagePreview,
  storageRows,
  toggled,
  toggledAll,
  usedShare,
  withRefused,
  type KeptRow,
  type StaleRow,
  type StorageDisk,
  type StoragePressure,
} from "./storageSectionModel";
import { WindowedRows } from "./WindowedRows";
import "./storageSection.css";

/// How long a report may take before the summary line says "Measuring…".
export const MEASURING_DELAY_MS = 300;

/// What the pane's acpmux client offers the section (App.tsx).
export type StorageSource = {
  /// `_acpmux/worktree/report {staleOnly: true}`.
  report(): Promise<unknown>;
  /// `_acpmux/worktree/clean {only, staleOnly: true}`. The host takes it only under the person's
  /// gesture, so `onFree` calls it straight from the click or the key, with nothing awaited first.
  clean(paths: readonly string[]): Promise<unknown>;
};

export type StorageLayout = "plain" | "grouped" | "summary";

/// Everything the section draws: StorageSection's props, from `useStorage` or a gallery fixture.
export type StorageView = {
  /// A report is on its way.
  loading: boolean;
  /// No report has come yet.
  empty: boolean;
  disk?: StorageDisk;
  pressure: StoragePressure;
  stale: readonly StaleRow[];
  kept: readonly KeptRow[];
  /// acpmux's own errors from the pass.
  errors: readonly string[];
  selected: ReadonlySet<string>;
  /// Rows a clean refused, with acpmux's words: they keep their place.
  failed: ReadonlyMap<string, string>;
  freeing: boolean;
  /// What the last clean freed, until the person picks again.
  freed?: number;
  /// The last request failed: another pass runs, or anything else.
  notice?: "busy" | "failed";
};

export type StorageActions = {
  onToggle: (path: string) => void;
  onToggleAll: () => void;
  onFree: () => void;
  onRefresh: () => void;
};

const NO_ROWS: readonly never[] = [];
const NO_FAILED: ReadonlyMap<string, string> = new Map();
const NO_SELECTION: ReadonlySet<string> = new Set();

type Known = Pick<StorageView, "disk" | "pressure" | "stale" | "kept" | "errors">;

/// The last report this page read, machine-wide: a section opened again (another chat's panel) starts
/// drawn with it while the new one comes, so nothing pops in.
let lastKnown: Known | undefined;
/// acpmux or the pane's host does not know the methods: no section on this page.
let unsupported = false;

/// Tests: forget the page's copy.
export function resetStorageForTests() {
  lastKnown = undefined;
  unsupported = false;
}

/// The section's state and actions while `open` (reads nothing before), or `hidden` where acpmux
/// cannot answer.
export function useStorage(
  source: StorageSource | undefined,
  open: boolean,
): { hidden: boolean; view: StorageView; actions: StorageActions } {
  const [known, setKnown] = useState<Known | undefined>(lastKnown);
  const [loading, setLoading] = useState(false);
  const asked = useRef(false);
  const [hidden, setHidden] = useState(unsupported);
  const [selected, setSelected] = useState<ReadonlySet<string>>(NO_SELECTION);
  const [failed, setFailed] = useState<ReadonlyMap<string, string>>(NO_FAILED);
  const [freeing, setFreeing] = useState(false);
  const [freed, setFreed] = useState<number>();
  const [notice, setNotice] = useState<"busy" | "failed">();
  const mounted = useRef(true);
  useEffect(
    () => () => {
      mounted.current = false;
    },
    [],
  );
  // Each read's number: an older answer that lands after a newer ask is dropped.
  const reads = useRef(0);
  // What the read after a clean keeps in place: the rows the clean refused (withRefused).
  const refused = useRef<{ rows: readonly StaleRow[]; failed: ReadonlyMap<string, string> }>({
    rows: NO_ROWS,
    failed: NO_FAILED,
  });

  const read = useCallback(() => {
    if (!source || unsupported) return;
    const at = ++reads.current;
    setLoading(true);
    source.report().then(
      (reply) => {
        const report = parseStorageReport(reply);
        if (!mounted.current || at !== reads.current) return;
        setLoading(false);
        if (!report) {
          setNotice("failed");
          return;
        }
        const rows = withRefused(storageRows(report), refused.current.rows, refused.current.failed);
        const next: Known = {
          ...(report.disk ? { disk: report.disk } : {}),
          pressure: report.pressure,
          stale: rows.stale,
          kept: rows.kept,
          errors: report.errors,
        };
        lastKnown = next;
        setKnown(next);
        setNotice(undefined);
        setSelected((now) => keptSelection(rows.stale, now));
      },
      (error: unknown) => {
        if (!mounted.current || at !== reads.current) return;
        setLoading(false);
        const kind = storageFailure(error);
        if (kind === "unsupported") {
          unsupported = true;
          setHidden(true);
        } else setNotice(kind);
      },
    );
  }, [source]);

  // Lazy: the first open reads; a fold and unfold after it reads nothing.
  useEffect(() => {
    if (!open || asked.current || !source) return;
    asked.current = true;
    read();
  }, [open, source, read]);

  const stale = known?.stale ?? NO_ROWS;
  const onFree = useCallback(() => {
    if (!source || freeing || loading) return;
    const paths = stale.filter((row) => selected.has(row.path)).map((row) => row.path);
    if (paths.length === 0) return;
    setFreeing(true);
    setNotice(undefined);
    source.clean(paths).then(
      (reply) => {
        if (!mounted.current) return;
        setFreeing(false);
        const report = parseStorageReport(reply);
        if (!report) {
          setNotice("failed");
          return;
        }
        // One commit: the freed rows leave, the refused ones stay with acpmux's words, and the
        // button gives its place to what was freed.
        const done = afterClean(stale, report, paths);
        refused.current = { rows: done.stale, failed: done.failed };
        setKnown((now) => {
          const next = now && { ...now, stale: done.stale };
          lastKnown = next;
          return next;
        });
        setFailed(done.failed);
        setSelected(NO_SELECTION);
        setFreed(done.freed);
        read();
      },
      (error: unknown) => {
        if (!mounted.current) return;
        setFreeing(false);
        const kind = storageFailure(error);
        if (kind === "unsupported") {
          unsupported = true;
          setHidden(true);
        } else setNotice(kind);
      },
    );
  }, [source, freeing, loading, stale, selected, read]);

  const pick = (next: ReadonlySet<string>) => {
    setSelected(next);
    setFreed(undefined);
  };
  const onToggle = (path: string) => pick(toggled(selected, path));
  const onToggleAll = () => pick(toggledAll(stale, selected));
  const onRefresh = () => {
    refused.current = { rows: NO_ROWS, failed: NO_FAILED };
    setFailed(NO_FAILED);
    setFreed(undefined);
    read();
  };
  return {
    hidden: hidden || !source,
    view: {
      loading,
      empty: !known,
      ...(known?.disk ? { disk: known.disk } : {}),
      pressure: known?.pressure ?? "normal",
      stale,
      kept: known?.kept ?? NO_ROWS,
      errors: known?.errors ?? NO_ROWS,
      selected,
      failed,
      freeing,
      ...(freed !== undefined ? { freed } : {}),
      ...(notice ? { notice } : {}),
    },
    actions: { onToggle, onToggleAll, onFree, onRefresh },
  };
}

/// The section's value beside its title: "This Mac", what the last report could free beside it.
export function useStorageMeta(view: StorageView): string {
  const t = useT();
  const language = usePaneLanguage();
  const bytes = view.stale.reduce((sum, row) => sum + (row.bytes ?? 0), 0);
  return bytes > 0
    ? `${t("sessionInfo.storage.thisMac")} · ${t("sessionInfo.storage.reclaimable", { size: storageBytes(bytes, language) })}`
    : t("sessionInfo.storage.thisMac");
}

export function StorageSection({
  view,
  actions,
  layout = "summary",
  measuringDelay = MEASURING_DELAY_MS,
}: {
  view: StorageView;
  actions: StorageActions;
  layout?: StorageLayout;
  /// The gallery's settled states show "Measuring…" at once (0).
  measuringDelay?: number;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const measuring = useAfterDelay(view.loading, measuringDelay);
  const [showKept, setShowKept] = useState(false);
  const keptFold = useFoldMotion<HTMLDivElement>(showKept, () => 0);
  const preview = storagePreview(view.stale, view.selected);
  const label = previewLabel(preview, language);
  const size = label.size
    ? label.size.unmeasured
      ? t("sessionInfo.storage.atLeast", { size: label.size.text })
      : label.size.text
    : undefined;
  const all = view.stale.length > 0 && view.stale.every((row) => view.selected.has(row.path));
  const busy = view.freeing || view.loading;

  // Return on a row's checkbox frees what is checked, as the button would.
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key !== "Enter" || event.defaultPrevented) return;
    if (preview.count === 0 || busy) return;
    event.preventDefault();
    actions.onFree();
  };

  const row = (item: StaleRow) => {
    const error = view.failed.get(item.path);
    const checked = view.selected.has(item.path);
    // The branch names the work a person remembers; every row here is merged, so the verdict's own
    // words (`item.reason`) are only the fallback. A refused clean's reason replaces both.
    const detail = error || item.branch || item.reason;
    return (
      <li
        key={item.path}
        className="acpmux-session-info-task acpmux-session-info-storage__row"
        data-failed={error !== undefined ? "" : undefined}
        title={item.branch ? `${item.path} (${item.branch})` : item.path}
      >
        <label className="acpmux-session-info-task__open acpmux-session-info-storage__pick">
          <input
            type="checkbox"
            className="acpmux-session-info-storage__check"
            aria-label={item.name}
            onKeyDown={onKeyDown}
            checked={checked}
            disabled={view.freeing}
            onChange={() => actions.onToggle(item.path)}
          />
          <span className="acpmux-session-info-task__command">{item.name}</span>
          {detail && (
            <span className="acpmux-session-info-storage__detail">{detail}</span>
          )}
          <span
            className="acpmux-session-info-task__time"
            title={item.bytes === undefined ? t("sessionInfo.storage.notMeasured") : undefined}
          >
            {storageBytes(item.bytes, language)}
          </span>
        </label>
      </li>
    );
  };

  const summary = layout === "summary" && view.disk && (
    <>
      <span
        className="acpmux-session-info-meter acpmux-session-info-storage__meter"
        data-pressure={view.pressure}
        aria-hidden="true"
      >
        <span style={{ width: `${Math.round(usedShare(view.disk) * 100)}%` }} />
      </span>
      <span className="acpmux-session-info-storage__disk">
        {t("sessionInfo.storage.disk", {
          free: storageBytes(view.disk.available, language),
          total: storageBytes(view.disk.total, language),
        })}
      </span>
    </>
  );
  const selectAll = view.stale.length > 0 && (
    <button type="button" className="acpmux-session-info-link" disabled={view.freeing} onClick={actions.onToggleAll}>
      {t(all ? "sessionInfo.storage.selectNone" : "sessionInfo.storage.selectAll")}
    </button>
  );

  // The one line where a state speaks: it holds its height whatever it says, so nothing under it moves.
  const status = view.notice ? (
    <p className="acpmux-session-info-note acpmux-session-info-storage__status" data-notice={view.notice}>
      {t(view.notice === "busy" ? "sessionInfo.storage.busy" : "sessionInfo.storage.failed")}{" "}
      <button type="button" className="acpmux-session-info-link" onClick={actions.onRefresh}>
        {t("sessionInfo.storage.tryAgain")}
      </button>
    </p>
  ) : view.empty ? (
    <p className="acpmux-session-info-note acpmux-session-info-storage__status" aria-live="polite">
      {measuring && t("sessionInfo.storage.measuring")}
    </p>
  ) : view.stale.length === 0 && view.freed === undefined ? (
    <p className="acpmux-session-info-note acpmux-session-info-storage__status">{t("sessionInfo.storage.empty")}</p>
  ) : null;

  return (
    <div className="acpmux-session-info-storage" data-layout={layout}>
      {!view.empty && (
        <div className="acpmux-session-info-storage__bar">
          {summary || selectAll || <span />}
          <span className="acpmux-session-info-storage__end">
            {measuring ? (
              <span className="acpmux-session-info-storage__measuring" aria-live="polite">
                {t("sessionInfo.storage.measuring")}
              </span>
            ) : (
              <button
                type="button"
                className="acpmux-session-info-icon-button"
                aria-label={t("sessionInfo.storage.refresh")}
                title={t("sessionInfo.storage.refresh")}
                disabled={busy}
                onClick={actions.onRefresh}
              >
                <Icon name="action.reload" size={12} />
              </button>
            )}
          </span>
        </div>
      )}
      {status}
      {view.stale.length > 0 && (
        <ul className="acpmux-session-info-list" data-storage-rows="">
          {layout === "grouped" ? (
            <WindowedRows
              items={groupedRows(view.stale)}
              render={(item) =>
                "caption" in item ? (
                  <li key={`caption:${item.caption}`} className="acpmux-session-info-storage__caption" aria-hidden>
                    {item.caption || t("sessionInfo.storage.noRepository")}
                  </li>
                ) : (
                  row(item.row)
                )
              }
            />
          ) : (
            <WindowedRows items={view.stale} render={row} />
          )}
        </ul>
      )}
      {view.errors.length > 0 && (
        <p className="acpmux-session-info-note acpmux-session-info-storage__errors" title={view.errors.join("\n")}>
          {view.errors[0]}
        </p>
      )}
      {(view.stale.length > 0 || view.freed !== undefined) && (
        <div className="acpmux-session-info-storage__foot">
          {view.freed !== undefined && preview.count === 0 && !view.freeing ? (
            <p className="acpmux-session-info-storage__freed" aria-live="polite">
              {view.freed > 0
                ? t("sessionInfo.storage.freed", { size: storageBytes(view.freed, language) })
                : t("sessionInfo.storage.freedNothing")}
            </p>
          ) : (
            <Button
              size="sm"
              variant={preview.count > 0 ? "solid" : "subtle"}
              className="acpmux-session-info-storage__free"
              disabled={preview.count === 0 || busy}
              onClick={actions.onFree}
            >
              {view.freeing
                ? t("sessionInfo.storage.freeing")
                : preview.count === 0
                  ? t("sessionInfo.storage.choose")
                  : size
                    ? `${t(label.key, label.values)} · ${size}`
                    : t(label.key, label.values)}
            </Button>
          )}
          {summary && selectAll}
        </div>
      )}
      {view.kept.length > 0 && (
        <>
          <SessionInfoFold open={showKept} onToggle={() => keptFold.toggle(!showKept, setShowKept)}>
            <Icon name="disclosure.collapsed" size={12} />
            {t("sessionInfo.storage.kept", { n: view.kept.length })}
          </SessionInfoFold>
          {keptFold.drawn && (
            <div ref={keptFold.ref} className="acpmux-session-info-fold-box">
              <ul className="acpmux-session-info-list" data-storage-kept="">
                <WindowedRows
                  items={view.kept}
                  render={(item) => (
                    <li key={item.path} className="acpmux-session-info-task" title={item.path}>
                      <span className="acpmux-session-info-task__command">{item.name}</span>
                      <span className="acpmux-session-info-storage__detail" title={item.reason}>
                        {item.reason}
                      </span>
                    </li>
                  )}
                />
              </ul>
            </div>
          )}
        </>
      )}
    </div>
  );
}

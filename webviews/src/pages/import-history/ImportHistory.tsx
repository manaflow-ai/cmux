import { useId, useState, useSyncExternalStore } from "react";
import { ChevronRight } from "../../agent-session/acpmux/conversation/icons";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import { DialogButton } from "../../ui/DialogButton";
import { Switch } from "../../ui/Switch";
import type { Strings } from "../shared/i18n";
import { canImport, type HistoryRow, type ImportHistoryStore, type Origin, type RowID } from "./model";

/** `groups` ships: two toggles (Chats, Memories) in one list, each source one level deeper behind
 * its group's Sources disclosure. `sections` and `tiles` are gallery alternatives. */
export type HistoryLayout = "groups" | "sections" | "tiles";
export interface ImportHistoryProps {
  store: ImportHistoryStore;
  strings: Strings;
  layout?: HistoryLayout;
  /** Opens every group's Sources at first draw (gallery states). */
  defaultOpen?: boolean;
}

export type GroupID = "chats" | "memories";
export const GROUPS: readonly GroupID[] = ["chats", "memories"];

/** Conversations and chat exports are chats; memory notes and pasted summaries are memories. */
export function groupOf(row: HistoryRow): GroupID {
  if (row.kind === "text" || row.id === "claude-memory" || row.id === "codex") return "memories";
  return "chats";
}

/** A row the importer can take now: found on this Mac, picked, or holding a pasted summary. */
export function isAvailable(row: HistoryRow): boolean {
  return row.kind === "text" ? Boolean(row.text?.trim()) : Boolean(row.source);
}

export function ImportHistory({ store, strings, layout = "groups", defaultOpen = false }: ImportHistoryProps) {
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
      {/* One scroll region holds everything above the footer, so nothing scrolls under a fixed
          header and no card is clipped beneath it. */}
      <div className="history-scroll">
        <div className="history-content">
          <header className="history-header">
            <h1>{t("history.title")}</h1>
            <p className="history-lead">{t("history.subtitle")}</p>
          </header>
          <div className="history-groups">
            {GROUPS.map((group) => (
              <Group
                key={group}
                group={group}
                rows={snapshot.rows.filter((row) => groupOf(row) === group)}
                store={store}
                strings={strings}
                busy={busy || snapshot.phase === "detecting"}
                alwaysOpen={layout === "sections"}
                defaultOpen={defaultOpen}
              />
            ))}
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
        <output className="history-notice" aria-live="polite">
          {t(`history.state.${snapshot.phase}`)}
        </output>
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

function Group({
  group,
  rows,
  store,
  strings,
  busy,
  alwaysOpen,
  defaultOpen,
}: {
  group: GroupID;
  rows: HistoryRow[];
  store: ImportHistoryStore;
  strings: Strings;
  busy: boolean;
  alwaysOpen: boolean;
  defaultOpen: boolean;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const t = strings.t;
  const id = useId();
  const [opened, setOpened] = useState(defaultOpen);
  const sorted = sortByTitle(rows, strings);
  const available = rows.filter(isAvailable);
  const included = available.filter((row) => row.selected);
  // A failed source or an open paste box needs its row seen: the group stays open while one does.
  const pinned = rows.some((row) => row.phase === "error" || (row.kind === "text" && row.expanded));
  const open = alwaysOpen || opened || pinned;
  const title = t(`history.group.${group}`);
  return (
    <section className={`history-group group-${group}`} aria-labelledby={`${id}-title`}>
      <div className="history-group-line">
        <div className="history-group-marks" aria-hidden="true">
          {uniqueMarks(available.length ? available : rows).map((mark) => (
            <span key={mark} className="history-source-icon">
              <AgentMark agent={mark} size={16} label="" fallback={<span>{mark.charAt(0).toUpperCase()}</span>} />
            </span>
          ))}
        </div>
        <div className="history-group-text">
          <label className="history-group-title" id={`${id}-title`} htmlFor={`${id}-switch`}>
            {title}
          </label>
          <span className="history-group-summary">{summary(sorted, included, available, snapshot.phase, strings)}</span>
        </div>
        {!alwaysOpen && (
          <button
            type="button"
            className="history-disclosure"
            aria-expanded={open}
            aria-controls={`${id}-sources`}
            aria-describedby={`${id}-title`}
            onClick={() => setOpened(!open)}
          >
            {t("history.group.sources")}
            <ChevronRight size={12} className="history-chevron" aria-hidden="true" />
          </button>
        )}
        <Switch
          id={`${id}-switch`}
          aria-labelledby={`${id}-title`}
          checked={available.length > 0 && included.length === available.length}
          disabled={busy || available.length === 0}
          onCheckedChange={(checked) => {
            // On from a partial selection turns every available source on; off turns them all off.
            for (const row of available) if (row.selected !== checked) store.select(row.id, checked);
          }}
        />
      </div>
      {open && (
        <div className="history-sources" id={`${id}-sources`}>
          {sorted.map((row) => (
            <SourceRow key={row.id} row={row} store={store} strings={strings} busy={busy} />
          ))}
          {group === "chats" && (
            <button
              type="button"
              className="history-link history-find"
              disabled={busy || Boolean(snapshot.picking)}
              onClick={() => void store.findExports()}
            >
              {t("history.findExports")}
            </button>
          )}
        </div>
      )}
    </section>
  );
}

/** The line under a group's title: what it brings, or its progress once Import runs. */
function summary(
  sorted: HistoryRow[],
  included: HistoryRow[],
  available: HistoryRow[],
  phase: string,
  strings: Strings,
): string {
  const t = strings.t;
  if (phase === "detecting") return t("history.row.planning");
  const running = included.filter((row) => row.phase !== "idle");
  if (running.some((row) => row.phase === "error")) return t("history.row.error");
  if (running.some((row) => row.phase === "planning" || row.phase === "writing")) return t("history.row.writing");
  if (running.length && running.every((row) => row.phase === "done")) {
    const written = running.reduce((sum, row) => sum + (row.report?.written ?? 0), 0);
    return `${t("history.row.done")} · ${strings.format("history.written", String(written))}`;
  }
  if (!available.length) return t("history.group.none");
  if (!included.length) return t("history.group.off");
  const names = sorted.filter((row) => included.includes(row)).map((row) => titleOf(row, strings));
  return new Intl.ListFormat(strings.language, { style: "short", type: "unit" }).format(names);
}

function SourceRow({
  row,
  store,
  strings,
  busy,
}: {
  row: HistoryRow;
  store: ImportHistoryStore;
  strings: Strings;
  busy: boolean;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const t = strings.t;
  const title = titleOf(row, strings);
  const sourceName = localizedTitle(row.id, strings) ?? title;
  const picking = busy || Boolean(snapshot.picking);
  const expanded = Boolean(row.expanded);
  // The path or file name a detected or picked source reads from; a local tool not found says so.
  const where = row.name ?? (row.kind === "local" && !row.source ? t("history.notFound") : undefined);
  return (
    <div className={`history-source phase-${row.phase}`}>
      <div className="history-source-line">
        <input
          type="checkbox"
          id={`history-select-${row.id}`}
          aria-label={title}
          checked={row.selected}
          disabled={busy || !isAvailable(row)}
          onChange={(event) => store.select(row.id, event.target.checked)}
        />
        <span className="history-source-icon">
          <AgentMark
            agent={markFor(row.id, row.title)}
            size={16}
            label=""
            fallback={<span aria-hidden="true">{title.charAt(0)}</span>}
          />
        </span>
        <span className="history-source-text">
          <label htmlFor={`history-select-${row.id}`}>{title}</label>
          {where && <span className="history-file">{where}</span>}
        </span>
        {row.kind === "zip" && (
          <button
            type="button"
            className="history-link"
            disabled={picking}
            onClick={() => void store.pickZip(row.id)}
            aria-label={strings.format("history.chooseFor", sourceName)}
          >
            {t(snapshot.picking === row.id ? "history.choosing" : "history.choose")}
          </button>
        )}
        {row.kind === "text" && (
          <button
            type="button"
            className="history-link"
            disabled={busy}
            aria-expanded={expanded}
            aria-controls={`history-paste-box-${row.id}`}
            onClick={() => store.expand(row.id)}
          >
            {t(expanded ? "history.hide" : "history.paste")}
          </button>
        )}
      </div>
      {row.kind === "text" && expanded && (
        <div className="history-paste" id={`history-paste-box-${row.id}`}>
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
    </div>
  );
}

/** Sources in alphabetical order of their shown title, in the page's language, so the list reads
 * the same on every launch whatever order detection returned them in. */
export function sortByTitle(rows: HistoryRow[], strings: Strings): HistoryRow[] {
  const collator = new Intl.Collator(strings.language, { sensitivity: "base" });
  return [...rows].sort((a, b) => collator.compare(titleOf(a, strings), titleOf(b, strings)));
}

function localizedTitle(id: RowID, strings: Strings): string | undefined {
  const key = `history.source.${id}`;
  const text = strings.t(key);
  return text === key ? undefined : text;
}

export function titleOf(row: HistoryRow, strings: Strings): string {
  return row.title ?? localizedTitle(row.id, strings) ?? titleFor(row.id);
}

function uniqueMarks(rows: HistoryRow[]): string[] {
  return [...new Set(rows.map((row) => markFor(row.id, row.title)))].slice(0, 3);
}

function markFor(id: string, title?: string): string {
  if (id === "claude" || id === "claude-code" || id === "claude-memory") return "claude";
  if (id === "codex" || id === "codex-sessions") return "codex";
  if (id === "chatgpt" || id === "dots" || id === "dot") return "chatgpt";
  if (id === "grok-bot" || title?.toLowerCase().includes("grok")) return "grok";
  if (id === "muse" || title?.toLowerCase().includes("muse")) return "muse";
  if (id === "instinct" || title?.toLowerCase().includes("instinct")) return "instinct";
  if (title?.toLowerCase().includes("dot")) return "chatgpt";
  return id;
}

function titleFor(id: string): string {
  return (
    {
      "codex-sessions": "Codex chats",
      "grok-bot": "Grok Bot",
      muse: "Muse",
      dots: "ChatGPT Dots",
      instinct: "Instinct",
    }[id] ?? "Saved export (.zip)"
  );
}

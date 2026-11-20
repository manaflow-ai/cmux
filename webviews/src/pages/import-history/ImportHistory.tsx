import { useId, useState, useSyncExternalStore } from "react";
import { ChevronRight } from "../../agent-session/acpmux/conversation/icons";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import { DialogButton } from "../../ui/DialogButton";
import type { Strings } from "../shared/i18n";
import { canImport, type HistoryRow, type ImportHistoryStore, type Origin, type RowID } from "./model";

/** `list` ships: one row per tool in one inset list, its sources one level deeper behind Sources.
 * `chips` puts a Chats and a Memories toggle on each tool's row; `cards` gives each tool its own card
 * with every source listed. Both are gallery alternatives. */
export type HistoryLayout = "list" | "chips" | "cards";
export interface ImportHistoryProps {
  store: ImportHistoryStore;
  strings: Strings;
  layout?: HistoryLayout;
  /** Opens every tool's Sources at first draw (gallery states). */
  defaultOpen?: boolean;
}

export type KindID = "chats" | "memories";
export const KINDS: readonly KindID[] = ["chats", "memories"];

/** Conversations and chat exports are chats; memory notes and pasted summaries are memories. */
export function kindOf(row: HistoryRow): KindID {
  if (row.kind === "text" || row.id === "claude-memory" || row.id === "codex") return "memories";
  return "chats";
}

export type ToolID = "chatgpt" | "claude" | "codex" | "dot" | "grok" | "instinct" | "muse" | "other";

/** The tool a source belongs to: its chats and its memories share one row. */
export function toolOf(row: Pick<HistoryRow, "id" | "title">): ToolID {
  switch (row.id) {
    case "claude-code":
    case "claude-memory":
    case "claude":
      return "claude";
    case "codex":
    case "codex-sessions":
      return "codex";
    case "chatgpt":
    case "dots":
      return "chatgpt";
    case "grok-bot":
      return "grok";
    case "muse":
      return "muse";
    case "instinct":
      return "instinct";
    case "dot":
      return "dot";
    default:
      return row.title?.toLowerCase().startsWith("dot") ? "dot" : "other";
  }
}

/** Product names stay as they are in every language; only the catch-all row is translated. */
const TOOL_NAMES: Record<Exclude<ToolID, "other">, string> = {
  chatgpt: "ChatGPT",
  claude: "Claude",
  codex: "Codex",
  dot: "Dot",
  grok: "Grok",
  instinct: "Instinct",
  muse: "Muse",
};

export function toolName(tool: ToolID, strings: Strings): string {
  return tool === "other" ? strings.t("history.tool.other") : TOOL_NAMES[tool];
}

/** The tools these rows belong to, in alphabetical order in the page's language; saved exports
 * that belong to no tool come last. */
export function toolsOf(rows: HistoryRow[], strings: Strings): ToolID[] {
  const collator = new Intl.Collator(strings.language, { sensitivity: "base" });
  const tools = [...new Set(rows.map(toolOf))];
  return tools.sort((a, b) =>
    a === "other" ? 1 : b === "other" ? -1 : collator.compare(toolName(a, strings), toolName(b, strings)),
  );
}

/** A row the importer can take now: found on this Mac, picked, or holding a pasted summary. */
export function isAvailable(row: HistoryRow): boolean {
  return row.kind === "text" ? Boolean(row.text?.trim()) : Boolean(row.source);
}

export function ImportHistory({ store, strings, layout = "list", defaultOpen = false }: ImportHistoryProps) {
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
          header and no row is clipped beneath it. */}
      <div className="history-scroll">
        <div className="history-content">
          <header className="history-header">
            <h1>{t("history.title")}</h1>
            <p className="history-lead">{t("history.subtitle")}</p>
          </header>
          <div className="history-tools">
            {toolsOf(snapshot.rows, strings).map((tool) => (
              <ToolRow
                key={tool}
                tool={tool}
                rows={snapshot.rows.filter((row) => toolOf(row) === tool)}
                store={store}
                strings={strings}
                busy={busy || snapshot.phase === "detecting"}
                layout={layout}
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
          <div className="history-notes">
            <p className="history-safety">{t("history.safety")}</p>
            <button
              type="button"
              className="history-link history-find"
              disabled={busy || snapshot.phase === "detecting" || Boolean(snapshot.picking)}
              onClick={() => void store.findExports()}
            >
              {t("history.findExports")}
            </button>
          </div>
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

/** Turns every available source in `rows` on or off. */
function selectAll(store: ImportHistoryStore, rows: HistoryRow[], selected: boolean): void {
  for (const row of rows) if (isAvailable(row) && row.selected !== selected) store.select(row.id, selected);
}

function ToolRow({
  tool,
  rows,
  store,
  strings,
  busy,
  layout,
  defaultOpen,
}: {
  tool: ToolID;
  rows: HistoryRow[];
  store: ImportHistoryStore;
  strings: Strings;
  busy: boolean;
  layout: HistoryLayout;
  defaultOpen: boolean;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const t = strings.t;
  const id = useId();
  const [opened, setOpened] = useState(defaultOpen);
  const available = rows.filter(isAvailable);
  const included = available.filter((row) => row.selected);
  const all = available.length > 0 && included.length === available.length;
  const some = included.length > 0 && !all;
  // A failed source or an open paste box needs its row seen: the tool stays open while one does.
  const pinned = rows.some((row) => row.phase === "error" || (row.kind === "text" && row.expanded));
  const alwaysOpen = layout === "cards";
  const open = alwaysOpen || opened || pinned;
  const name = toolName(tool, strings);
  const kinds = KINDS.filter((kind) => rows.some((row) => kindOf(row) === kind));
  return (
    <section className={`history-tool tool-${tool}`} aria-labelledby={`${id}-title`}>
      <div className="history-tool-line">
        <input
          type="checkbox"
          id={`${id}-check`}
          ref={(input) => {
            if (input) input.indeterminate = some;
          }}
          checked={all}
          disabled={busy || available.length === 0}
          aria-labelledby={`${id}-title`}
          aria-describedby={`${id}-summary`}
          onChange={(event) => selectAll(store, rows, event.target.checked)}
        />
        <span className="history-source-icon" aria-hidden="true">
          <AgentMark agent={tool} size={16} label="" fallback={<span>{name.charAt(0)}</span>} />
        </span>
        <span className="history-tool-text">
          <label className="history-tool-title" id={`${id}-title`} htmlFor={`${id}-check`}>
            {name}
          </label>
          <span className="history-tool-summary" id={`${id}-summary`}>
            {summary(included, available, snapshot.phase, strings)}
          </span>
        </span>
        {layout === "chips" && (
          <span className="history-kind-chips">
            {kinds.map((kind) => {
              const ofKind = available.filter((row) => kindOf(row) === kind);
              const on = ofKind.length > 0 && ofKind.every((row) => row.selected);
              return (
                <button
                  key={kind}
                  type="button"
                  className="history-chip"
                  aria-pressed={on}
                  disabled={busy || ofKind.length === 0}
                  onClick={() => selectAll(store, ofKind, !on)}
                >
                  {t(`history.group.${kind}`)}
                </button>
              );
            })}
          </span>
        )}
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
      </div>
      {open && (
        <div className="history-sources" id={`${id}-sources`}>
          {kinds.map((kind) => (
            <fieldset key={kind} className={`history-kind kind-${kind}`}>
              <legend className="history-kind-title">{t(`history.group.${kind}`)}</legend>
              {sortByTitle(
                rows.filter((row) => kindOf(row) === kind),
                strings,
              ).map((row) => (
                <SourceRow key={row.id} row={row} store={store} strings={strings} busy={busy} />
              ))}
            </fieldset>
          ))}
        </div>
      )}
    </section>
  );
}

/** The line under a tool's name: which kinds it brings, or its progress once Import runs. */
function summary(included: HistoryRow[], available: HistoryRow[], phase: string, strings: Strings): string {
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
  const kinds = KINDS.filter((kind) => included.some((row) => kindOf(row) === kind));
  return kinds.length === KINDS.length ? t("history.tool.both") : t(`history.group.${kinds[0]}`);
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

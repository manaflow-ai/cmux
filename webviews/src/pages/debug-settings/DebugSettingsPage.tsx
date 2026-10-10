// Debug Settings (cmux-page://cmux.debug-settings/, DEV and NIGHTLY builds): a sidebar of tunable
// sections with search, and the visible tunables under a toolbar with the exports and resets. The
// app owns every value and the view state (DebugSettingsModel); this file renders what it sends and
// turns clicks and plain keys into intents. Every row comes from the registry's data.
import { useSyncExternalStore, type KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import type { DebugSettingsStore } from "./store";
import { TunableControlView } from "./TunableControl";
import type { DebugSettingsState, TunableRow } from "./types";

/** `%lld` and `%@` placeholders of the shared Swift catalog, in order. */
export function fill(text: string, ...args: Array<string | number>): string {
  let next = 0;
  return text.replace(/%(?:\d+\$)?(?:lld|ld|d|@)|%%/g, (match) => (match === "%%" ? "%" : String(args[next++] ?? "")));
}

function plain(event: KeyboardEvent): boolean {
  return !event.metaKey && !event.ctrlKey && !event.altKey;
}

function title(state: DebugSettingsState, query: string, t: Strings["t"]): string {
  if (query.trim()) return `“${query}”`;
  if (state.selection === "all") return t("debugSettings.all");
  if (state.selection === "changed") return t("debugSettings.changed");
  return state.sections.find((section) => section.id === state.selection)?.title ?? t("debugSettings.all");
}

function SidebarRow({
  label,
  count,
  changed,
  selected,
  onSelect,
  testId,
}: {
  label: string;
  count: number;
  changed: number;
  selected: boolean;
  onSelect(): void;
  testId: string;
}) {
  return (
    <button
      type="button"
      className="ds-sidebar-row"
      aria-current={selected ? "true" : undefined}
      onClick={onSelect}
      data-testid={testId}
    >
      <span className="ds-sidebar-label">{label}</span>
      {changed > 0 ? <span className="ds-dot" aria-hidden="true" /> : null}
      <span className="ds-count">{count}</span>
    </button>
  );
}

function Row({ row, store, strings }: { row: TunableRow; store: DebugSettingsStore; strings: Strings }) {
  return (
    <div className="ds-row" data-testid={`ds.row.${row.key}`} data-changed={row.changed ? "true" : undefined}>
      <div className="ds-row-text">
        <div className="ds-row-label">
          <span className="ds-dot" aria-hidden="true" data-visible={row.changed ? "true" : undefined} />
          {row.label}
        </div>
        <div className="ds-row-key">{row.key}</div>
        {row.help ? <div className="ds-row-help">{row.help}</div> : null}
      </div>
      <div className="ds-row-control">
        <TunableControlView row={row} onChange={(value) => void store.setValue(row.key, value)} />
        <div className="ds-row-default">{row.default_text}</div>
      </div>
      <button
        type="button"
        className="ds-row-reset"
        title={strings.t("settingsWindow.reset")}
        aria-label={`${strings.t("settingsWindow.reset")} ${row.label}`}
        disabled={!row.changed}
        onClick={() => void store.reset({ key: row.key })}
        data-testid={`ds.reset.${row.key}`}
      >
        ↺
      </button>
    </div>
  );
}

export function DebugSettingsPage({ store, strings }: { store: DebugSettingsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  const state = snap.state;
  if (!state) {
    return (
      <div className="ds-page ds-empty" data-connection={snap.connection}>
        {snap.error ?? ""}
      </div>
    );
  }
  const query = snap.query;
  const searching = query.trim() !== "";
  const section = state.sections.find((entry) => entry.id === state.selection);
  const searchKeys = (event: KeyboardEvent<HTMLInputElement>) => {
    if (plain(event) && event.key === "Escape" && query) {
      void store.setQuery("");
      event.preventDefault();
      event.stopPropagation();
    }
  };
  return (
    <div className="ds-page" data-connection={snap.connection}>
      <nav className="ds-sidebar" aria-label={t("debugSettings.title")}>
        <div className="ds-search-box">
          <input
            type="search"
            className="ds-search"
            placeholder={t("debugSettings.search")}
            aria-label={t("debugSettings.search")}
            value={query}
            onChange={(event) => void store.setQuery(event.currentTarget.value)}
            onKeyDown={searchKeys}
            data-testid="ds.search"
          />
        </div>
        <SidebarRow
          label={t("debugSettings.all")}
          count={state.total}
          changed={0}
          selected={!searching && state.selection === "all"}
          onSelect={() => void store.select("all")}
          testId="ds.section.all"
        />
        <SidebarRow
          label={t("debugSettings.changed")}
          count={state.changed}
          changed={0}
          selected={state.selection === "changed"}
          onSelect={() => void store.select("changed")}
          testId="ds.section.changed"
        />
        <div className="ds-sidebar-separator" role="separator" />
        {state.sections.map((entry) => (
          <SidebarRow
            key={entry.id}
            label={entry.title}
            count={entry.count}
            changed={entry.changed}
            selected={!searching && state.selection === entry.id}
            onSelect={() => void store.select(entry.id)}
            testId={`ds.section.${entry.id}`}
          />
        ))}
      </nav>
      <main className="ds-main">
        <header className="ds-toolbar" data-titlebar="">
          <div className="ds-title-row">
            <h1 className="ds-title">{title(state, query, t)}</h1>
            <span className="ds-title-count">{fill(t("debugSettings.count"), state.visible)}</span>
          </div>
          <div className="ds-actions">
            <button type="button" className="ds-button" onClick={() => void store.copy("json")} data-testid="ds.copyJSON">
              {t("debugSettings.copyJSON")}
            </button>
            <button type="button" className="ds-button" onClick={() => void store.copy("swift")} data-testid="ds.copySwift">
              {t("debugSettings.copySwift")}
            </button>
            {section ? (
              <button
                type="button"
                className="ds-button"
                disabled={section.changed === 0}
                onClick={() => void store.reset({ section: section.id })}
                data-testid="ds.resetSection"
              >
                {t("debugSettings.resetSection")}
              </button>
            ) : null}
            <button
              type="button"
              className="ds-button ds-destructive"
              disabled={state.changed === 0}
              onClick={() => void store.reset({ all: true })}
              data-testid="ds.resetAll"
            >
              {t("debugSettings.resetAll")}
            </button>
          </div>
          {state.notice || snap.error ? (
            <div className="ds-notice" role="status">
              {snap.error ?? state.notice}
            </div>
          ) : null}
        </header>
        <div className="ds-scroll">
          {state.groups.length === 0 ? (
            <p className="ds-none">
              {state.selection === "changed" && !searching ? t("debugSettings.nothingChanged") : t("debugSettings.noResults")}
            </p>
          ) : null}
          {state.groups.map((group) => (
            <section key={group.id} className="ds-card" aria-label={group.title}>
              <h2 className="ds-card-title">{group.title}</h2>
              <div className="ds-card-body">
                {group.rows.map((row) => (
                  <Row key={row.key} row={row} store={store} strings={strings} />
                ))}
              </div>
            </section>
          ))}
          <p className="ds-footer">{t("debugSettings.footer")}</p>
        </div>
      </main>
    </div>
  );
}

// The History page's Cookie Backups panel (decision D3 on cmux#13742): the sites whose cookies an
// agent cleared in a WebKit tab, with the encrypted copy cmux keeps on this Mac so the agent can
// undo the clear. Only the person deletes a copy: Delete and Delete All ask in the app's own
// dialog (page script cannot answer it). A panel over the page, so the timeline under it never
// moves; Escape or Done closes it.
import { useEffect, useRef, type KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import type { HistorySnapshot, HistoryStore } from "./store";

export function CookieBackupsPanel({
  store,
  state,
  strings,
}: {
  store: HistoryStore;
  state: HistorySnapshot["cookieBackups"];
  strings: Strings;
}) {
  const { t, language } = strings;
  const done = useRef<HTMLButtonElement>(null);
  const opener = useRef<Element | null>(null);
  useEffect(() => {
    opener.current = document.activeElement;
    done.current?.focus();
    return () => {
      if (opener.current instanceof HTMLElement) opener.current.focus();
    };
  }, []);
  const date = new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" });
  const keys = (event: KeyboardEvent) => {
    if (event.key !== "Escape" || event.metaKey || event.ctrlKey || event.altKey) return;
    event.preventDefault();
    store.hideCookieBackups();
  };
  const { backups } = state;
  return (
    <div className="history-sheet-scrim">
      <dialog open className="ui-glass history-sheet" aria-modal="true" aria-labelledby="cookie-backups-title" onKeyDown={keys}>
        <h2 id="cookie-backups-title" className="history-sheet-title">
          {t("cookieBackups.title")}
        </h2>
        <p className="history-sheet-text">{t("cookieBackups.explanation")}</p>
        {state.error ? (
          <p className="history-sheet-text" role="alert">
            {state.error}
          </p>
        ) : null}
        {backups.length === 0 ? (
          <div className="history-sheet-empty">{state.loading ? "" : t("cookieBackups.empty")}</div>
        ) : (
          <ul className="history-sheet-list">
            {backups.map((backup) => (
              <li key={backup.id} className="history-sheet-row">
                <span className="history-row-text">
                  <span className={`history-row-title${backup.site ? "" : " unreadable"}`}>
                    {backup.site ?? t("cookieBackups.unreadable")}
                  </span>
                  <span className="history-row-detail">{date.format(backup.created_at_ms)}</span>
                </span>
                <button
                  type="button"
                  className="history-menu-button"
                  onClick={() => void store.deleteCookieBackups([backup.id])}
                >
                  {t("cookieBackups.delete")}
                </button>
              </li>
            ))}
          </ul>
        )}
        <div className="history-sheet-actions">
          <button
            type="button"
            className="history-menu-button destructive"
            disabled={backups.length === 0}
            onClick={() => void store.deleteCookieBackups(backups.map((backup) => backup.id))}
          >
            {t("cookieBackups.deleteAll")}
          </button>
          <button ref={done} type="button" className="history-sheet-done" onClick={() => store.hideCookieBackups()}>
            {t("cookieBackups.done")}
          </button>
        </div>
      </dialog>
    </div>
  );
}

// The History page's Cookie Backups panel (decision D3 on cmux#13742): the sites whose cookies an
// agent cleared in a WebKit tab, with the encrypted copy cmux keeps on this Mac so the agent can
// undo the clear. Only the person deletes a copy: a row's menu (a right-click, or Shift-F10 / the
// context-menu key on the focused row) and Delete All ask in the app's own dialog (page script
// cannot answer it). A row carries no destructive control of its own. A modal dialog over the
// page (`showModal`): the timeline under it is inert and never moves, Tab and Shift-Tab stay inside
// until it closes, and Escape or Done closes it.
import { useLayoutEffect, useRef, useState, type KeyboardEvent, type MouseEvent } from "react";
import type { Strings } from "../shared/i18n";
import { PageMenu, pageMenuKey, type PageMenuItem } from "../shared/PageMenu";
import { UiProvider, usePopupHost, useUiDirection } from "../../ui/UiProvider";
import type { HistorySnapshot, HistoryStore } from "./store";

type OpenMenu = { session: number; x: number; y: number; items: PageMenuItem[]; returnFocus: HTMLElement | null };

const TABBABLE = 'button:not(:disabled), [href], input:not(:disabled), [tabindex]:not([tabindex="-1"])';

/** Tab past the last control goes to the first, Shift-Tab before the first to the last: focus
 * never leaves the dialog for the inert page or the window's chrome. */
export function wrapTab(dialog: HTMLElement, event: KeyboardEvent): void {
  if (event.key !== "Tab" || event.metaKey || event.ctrlKey || event.altKey) return;
  // In document order (a selector list's matches are not ordered in every DOM).
  const stops = [...dialog.querySelectorAll<HTMLElement>(TABBABLE)].sort((a, b) =>
    a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1,
  );
  const first = stops[0];
  const last = stops.at(-1);
  if (!first || !last) {
    event.preventDefault();
    return;
  }
  const active = dialog.ownerDocument.activeElement;
  const inside = active instanceof Node && dialog.contains(active);
  if (event.shiftKey && (active === first || !inside)) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && (active === last || !inside)) {
    event.preventDefault();
    first.focus();
  }
}

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
  const dialog = useRef<HTMLDialogElement>(null);
  // The row menu's fallback renders inside the dialog (a modal dialog leaves the rest inert), in a
  // zero-size layer out of the sheet's flow, so an open menu never moves the sheet.
  const [layer, setLayer] = useState<HTMLDivElement | null>(null);
  const done = useRef<HTMLButtonElement>(null);
  const [menu, setMenu] = useState<OpenMenu | null>(null);
  const menuSession = useRef(0);
  const dir = useUiDirection();
  const popupHost = usePopupHost();
  useLayoutEffect(() => {
    const element = dialog.current;
    if (!element) return;
    const opener = element.ownerDocument.activeElement;
    if (!element.open) element.showModal();
    done.current?.focus();
    return () => {
      if (element.open) element.close();
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus();
    };
  }, []);
  const date = new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" });
  const keys = (event: KeyboardEvent) => {
    // An open row menu owns its keys (its Escape closes the menu, not the dialog).
    if (menu || event.defaultPrevented) return;
    if (dialog.current) wrapTab(dialog.current, event);
    if (event.key !== "Escape" || event.metaKey || event.ctrlKey || event.altKey) return;
    event.preventDefault();
    store.hideCookieBackups();
  };
  const { backups } = state;
  const rowItems = (id: string): PageMenuItem[] => [
    {
      id: "delete",
      label: t("cookieBackups.delete"),
      destructive: true,
      run: () => void store.deleteCookieBackups([id]),
    },
  ];
  const showMenu = (x: number, y: number, returnFocus: HTMLElement | null, items: PageMenuItem[]) =>
    setMenu({ session: ++menuSession.current, x, y, items, returnFocus });
  const rowMenu = (event: MouseEvent<HTMLElement>, id: string) => {
    event.preventDefault();
    showMenu(event.clientX, event.clientY, event.currentTarget, rowItems(id));
  };
  const rowKeys = (event: KeyboardEvent<HTMLElement>, id: string) => {
    const at = pageMenuKey(event);
    if (at) showMenu(at.x, at.y, at.returnFocus, rowItems(id));
  };
  return (
    <div className="history-sheet-scrim">
      <dialog
        ref={dialog}
        className="ui-glass history-sheet"
        aria-labelledby="cookie-backups-title"
        onKeyDown={keys}
        onCancel={(event) => {
          // Escape the dialog saw itself (focus on no control): close through the store, as Done does.
          event.preventDefault();
          if (!menu) store.hideCookieBackups();
        }}
      >
        <div ref={setLayer} className="history-sheet-layer" />
        <UiProvider container={layer} dir={dir} popupHost={popupHost}>
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
                // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions
                <li
                  key={backup.id}
                  className="history-sheet-row"
                  // A focused row takes Shift-F10 for its menu, its only action (no button of its own).
                  // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex
                  tabIndex={0}
                  onContextMenu={(event) => rowMenu(event, backup.id)}
                  onKeyDown={(event) => rowKeys(event, backup.id)}
                >
                  <span className="history-row-text">
                    <span className={`history-row-title${backup.site ? "" : " unreadable"}`}>
                      {backup.site ?? t("cookieBackups.unreadable")}
                    </span>
                    <span className="history-row-detail">{date.format(backup.created_at_ms)}</span>
                  </span>
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
          {menu && (
            <PageMenu
              key={menu.session}
              x={menu.x}
              y={menu.y}
              items={menu.items}
              returnFocus={menu.returnFocus}
              onClose={() => setMenu(null)}
            />
          )}
        </UiProvider>
      </dialog>
    </div>
  );
}

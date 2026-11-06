// The Stashed Tabs page (a OneTab of cmux's own): stashed groups, newest first, each dated and
// named after its workspace, one compact line per page or workspace. A row's click restores it; its
// × or menu deletes it behind the app's Undo toast. State lives in `StashStore`; this file renders
// it and turns plain keys and clicks into store intents. Cmd/Ctrl chords never reach it.
import { useRef, useState, useSyncExternalStore, type MouseEvent } from "react";
import { PageMenu, type PageMenuItem } from "../shared/PageMenu";
import type { Strings } from "../shared/i18n";
import { useLasting } from "../../ui/lasting";
import { isWorkspace, matchGroups, memberHost, memberTitle, workspaceTabs } from "./model";
import type { StashNotice, StashStore } from "./store";
import type { StashGroup, StashMember } from "./types";

type OpenMenu = { session: number; x: number; y: number; items: PageMenuItem[]; returnFocus: HTMLElement | null };

const ICONS = {
  // Globe: circle, equator, meridian (the History page's page glyph).
  page: "M8 1.75a6.25 6.25 0 1 0 0 12.5 6.25 6.25 0 0 0 0-12.5ZM1.75 8h12.5M8 1.75c1.9 1.8 2.75 3.9 2.75 6.25S9.9 12.45 8 14.25C6.1 12.45 5.25 10.35 5.25 8S6.1 3.55 8 1.75Z",
  // A window with a sidebar: a workspace.
  workspace: "M2.25 3.25h11.5v9.5H2.25ZM5.75 3.25v9.5",
  close: "M4.5 4.5l7 7M11.5 4.5l-7 7",
};

function Glyph({ path }: { path: string }) {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d={path}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function noticeText(notice: StashNotice, strings: Strings): string {
  switch (notice.kind) {
    case "error":
      return notice.message;
    case "nothingToImport":
      return strings.t("stash.import.nothing");
    case "imported":
      return strings.format("stash.import.result", `${notice.imported}`, `${notice.skipped}`);
  }
}

export function StashPage({ store, strings }: { store: StashStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [menu, setMenu] = useState<OpenMenu | null>(null);
  const menuSession = useRef(0);
  const { t, language } = strings;
  const down = snap.connection === "disconnected";
  const downLasting = useLasting(down);
  const shown = matchGroups(snap.groups, snap.query);
  const time = new Intl.DateTimeFormat(language, { timeStyle: "short" });
  const date = new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" });
  const count = new Intl.NumberFormat(language);
  const off = snap.busy || down;

  const openMenu = (event: MouseEvent, items: PageMenuItem[]) => {
    event.preventDefault();
    setMenu({
      session: ++menuSession.current,
      x: event.clientX,
      y: event.clientY,
      items,
      returnFocus: event.currentTarget instanceof HTMLElement ? event.currentTarget : null,
    });
  };

  const groupItems = (group: StashGroup): PageMenuItem[] => [
    { id: "restore", label: t("stash.restoreAll"), run: () => void store.restore(group) },
    { id: "new", label: t("stash.restoreInNewWorkspace"), run: () => void store.restore(group, undefined, true) },
    {
      id: "delete",
      label: t("stash.deleteGroup"),
      destructive: true,
      separatorBefore: true,
      run: () => void store.delete(group),
    },
  ];

  const memberItems = (group: StashGroup, member: StashMember): PageMenuItem[] => [
    { id: "restore", label: t("stash.restore"), run: () => void store.restore(group, [member]) },
    {
      id: "delete",
      label: t("stash.delete"),
      destructive: true,
      separatorBefore: true,
      run: () => void store.delete(group, member),
    },
  ];

  return (
    <div className="stash-page" aria-busy={snap.busy || undefined}>
      <header className="stash-header">
        <div className="stash-title-row">
          <h1 className="stash-title">{t("stash.title")}</h1>
          {!snap.importOpen && (
            <button type="button" className="stash-text-button" disabled={off} onClick={() => store.openImport()}>
              {t("stash.import.button")}
            </button>
          )}
        </div>
        {snap.groups.length > 0 && (
          <input
            className="stash-search"
            type="search"
            placeholder={t("stash.search")}
            aria-label={t("stash.search")}
            value={snap.query}
            onChange={(event) => store.setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape" && snap.query && !event.metaKey && !event.ctrlKey && !event.altKey) {
                store.setQuery("");
                event.preventDefault();
              }
            }}
          />
        )}
        {snap.importOpen && (
          <div className="stash-import">
            <p className="stash-import-hint">{t("stash.import.hint")}</p>
            <textarea
              className="stash-import-text"
              aria-label={t("stash.import.button")}
              value={snap.importText}
              disabled={off}
              // oxlint-disable-next-line jsx-a11y/no-autofocus
              autoFocus
              onChange={(event) => store.setImportText(event.target.value)}
            />
            <div className="stash-import-actions">
              <button type="button" className="stash-text-button" onClick={() => store.closeImport()}>
                {t("stash.import.cancel")}
              </button>
              <button
                type="button"
                className="stash-text-button primary"
                disabled={off || !snap.importText.trim()}
                onClick={() => void store.importPasted()}
              >
                {t("stash.import.action")}
              </button>
            </div>
          </div>
        )}
        {snap.notice && (
          <p className="stash-notice" role={snap.notice.kind === "error" ? "alert" : "status"}>
            {noticeText(snap.notice, strings)}
          </p>
        )}
      </header>
      {down && !downLasting ? null : down ? (
        <output className="stash-empty">{t("stash.disconnected")}</output>
      ) : shown.length === 0 ? (
        <div className="stash-empty">
          {snap.loading ? "" : t(snap.groups.length ? "stash.noMatches" : "stash.empty")}
        </div>
      ) : (
        <div className="stash-list">
          {shown.map((group) => {
            // Restore All and Delete Group take the whole group, not only the members a search shows.
            const whole = snap.groups.find((candidate) => candidate.id === group.id) ?? group;
            const name = group.name || t("stash.untitled");
            return (
              <section key={group.id} className="stash-group" aria-label={name}>
                <div className="stash-group-header" onContextMenu={(event) => openMenu(event, groupItems(whole))}>
                  <h2 className="stash-group-name">{name}</h2>
                  <span className="stash-meta">{date.format(group.created_at_ms)}</span>
                  <span className="stash-meta stash-count">{count.format(whole.members.length)}</span>
                  <span className="stash-group-actions">
                    <button
                      type="button"
                      className="stash-text-button"
                      disabled={off}
                      onClick={() => void store.restore(whole)}
                    >
                      {t("stash.restoreAll")}
                    </button>
                    <button
                      type="button"
                      className="stash-text-button"
                      disabled={off}
                      onClick={() => void store.restore(whole, undefined, true)}
                    >
                      {t("stash.restoreInNewWorkspace")}
                    </button>
                    <button
                      type="button"
                      className="stash-text-button danger"
                      disabled={off}
                      onClick={() => void store.delete(whole)}
                    >
                      {t("stash.deleteGroup")}
                    </button>
                  </span>
                </div>
                {group.members.map((member) => {
                  const tabs = workspaceTabs(member);
                  const workspace = isWorkspace(member);
                  const aside = workspace
                    ? tabs.length
                      ? new Intl.ListFormat(language, { style: "narrow" }).format(tabs)
                      : undefined
                    : memberHost(member);
                  return (
                    <div
                      key={member.id}
                      className="stash-row"
                      onContextMenu={(event) => openMenu(event, memberItems(whole, member))}
                    >
                      <button
                        type="button"
                        className="stash-row-main"
                        disabled={off}
                        title={workspace ? tabs.join("\n") : member.url}
                        onClick={() => void store.restore(whole, [member])}
                      >
                        <span className="stash-row-icon">
                          <Glyph path={workspace ? ICONS.workspace : ICONS.page} />
                        </span>
                        <span className="stash-row-title">{memberTitle(member, t("stash.untitledWorkspace"))}</span>
                        {aside && <span className="stash-row-aside">{aside}</span>}
                        <span className="stash-row-time">{time.format(group.created_at_ms)}</span>
                      </button>
                      <button
                        type="button"
                        className="stash-row-delete"
                        disabled={off}
                        title={t("stash.delete")}
                        aria-label={t("stash.delete")}
                        onClick={() => void store.delete(whole, member)}
                      >
                        <Glyph path={ICONS.close} />
                      </button>
                    </div>
                  );
                })}
              </section>
            );
          })}
        </div>
      )}
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
    </div>
  );
}

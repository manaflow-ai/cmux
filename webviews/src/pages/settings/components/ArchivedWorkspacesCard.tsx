// Settings > Sidebar > Archived Workspaces (cmux#51635): the sidebar draws no archived row, so this card
// lists them, like ChatGPT's Settings > Data controls > Archived chats. Each row names the workspace (or
// link) and where it sits, with Open, Restore and Delete; Delete asks first, inline. Open shows it (it
// stays archived, as an archived chat opens in ChatGPT); Restore puts it back in the sidebar where it
// was; Delete closes it. The host runs each (`cmux.settings.archived.run`); the page only forwards.
// Opened at this card by `#/settings/sidebar?focus=card.archivedWorkspaces`. The list is read with the
// section (sectionQueries) and after each action; it does not poll.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useLayoutEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import type { ArchivedAction, ArchivedEntryWire } from "../ops";
import { ARCHIVED_KEY, archivedQuery } from "../sectionQueries";
import { t } from "../strings";

/** A row's key: a workspace and a link may share an id. */
const rowKey = (row: ArchivedEntryWire) => `${row.kind}:${row.id}`;

/** The line under the name: the group and the computer, or "Link" for a link, tab or app row. */
export function archivedDetail(row: ArchivedEntryWire): string {
  if (row.kind === "item") return t("settingsPage.archived.kindLink");
  return [row.group, row.machine].filter((part): part is string => !!part && part.trim() !== "").join(" · ");
}

export function ArchivedWorkspacesCard({ reveal = false }: { reveal?: boolean }) {
  const store = useStore();
  const queryClient = useQueryClient();
  const query = useQuery(archivedQuery(store));
  const state = query.data ?? null;
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const card = useRef<HTMLElement>(null);
  const drawn = query.isFetched;
  useLayoutEffect(() => {
    if (drawn && reveal) card.current?.scrollIntoView?.({ block: "start" });
  }, [drawn, reveal]);
  const rows = state?.available ? (state.rows ?? []) : [];
  const run = async (action: ArchivedAction, row: ArchivedEntryWire) => {
    setBusy(true);
    try {
      setError(await store.runArchived({ action, kind: row.kind, id: row.id }));
      await queryClient.invalidateQueries({ queryKey: ARCHIVED_KEY });
    } finally {
      setBusy(false);
      setConfirming(null);
    }
  };
  const unavailable = drawn && (state === null || !state.available);
  return (
    <section className="group" data-card="archivedWorkspaces" id="archived-workspaces" ref={card}>
      <h3 className="group-title">{t("settingsPage.archived.title")}</h3>
      <div className="rows">
        {unavailable ? (
          <div className="row" data-archived-unavailable="">
            <span className="row-help">{t("settingsPage.archived.unavailable")}</span>
          </div>
        ) : drawn && rows.length === 0 ? (
          <div className="row" data-archived-empty="">
            <span className="row-help">{t("settingsPage.archived.empty")}</span>
          </div>
        ) : (
          rows.map((row) => {
            const key = rowKey(row);
            const name = row.title.trim() || t("settingsPage.archived.untitled");
            const detail = archivedDetail(row);
            if (confirming === key) {
              const title = t("settingsPage.archived.deleteTitle", name);
              return (
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                <div className="accounts-form" data-archived-confirm={key} key={key} role="group" aria-label={title}>
                  <div className="row-title">{title}</div>
                  <div className="row-help">
                    {t(
                      row.kind === "item" ? "settingsPage.archived.deleteItemBody" : "settingsPage.archived.deleteBody",
                    )}
                  </div>
                  <div className="accounts-buttons">
                    <Button
                      danger
                      variant="ghost"
                      className="button"
                      data-archived-action="confirmDelete"
                      disabled={busy}
                      onClick={() => void run("delete", row)}
                    >
                      {t("settingsPage.archived.delete")}
                    </Button>
                    <Button className="button" data-archived-action="cancel" onClick={() => setConfirming(null)}>
                      {t("settingsPage.cancel")}
                    </Button>
                  </div>
                </div>
              );
            }
            return (
              <div className="row" data-archived={key} key={key}>
                <div className="row-main">
                  <div className="row-label">
                    <div className="row-title">{name}</div>
                    {detail && (
                      <div className="row-help" data-archived-detail="">
                        {detail}
                      </div>
                    )}
                  </div>
                  <span className="row-control">
                    <Button
                      variant="ghost"
                      className="button"
                      data-archived-action="open"
                      aria-label={t("settingsPage.archived.openNamed", name)}
                      disabled={busy}
                      onClick={() => void run("open", row)}
                    >
                      {t("settingsPage.archived.open")}
                    </Button>
                    <Button
                      variant="ghost"
                      className="button"
                      data-archived-action="restore"
                      aria-label={t("settingsPage.archived.restoreNamed", name)}
                      disabled={busy}
                      onClick={() => void run("restore", row)}
                    >
                      {t("settingsPage.archived.restore")}
                    </Button>
                    <Button
                      danger
                      variant="ghost"
                      className="button"
                      data-archived-action="delete"
                      aria-label={t("settingsPage.archived.deleteNamed", name)}
                      disabled={busy}
                      onClick={() => setConfirming(key)}
                    >
                      {t("settingsPage.archived.delete")}
                    </Button>
                  </span>
                </div>
              </div>
            );
          })
        )}
      </div>
      {error && (
        <div className="row-error" role="alert" data-archived-error="">
          {t("settingsPage.archived.failed", error)}
        </div>
      )}
    </section>
  );
}

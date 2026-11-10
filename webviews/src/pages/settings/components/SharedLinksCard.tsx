// Settings > Privacy and Security > Shared Links (design chat-multiplayer.md 2, "Shared links"): every
// chat this Mac shared by link or by invite, like ChatGPT's Settings > Data controls > Shared links.
// Each row names the chat, what kind of share it is, when it was shared and when it ends, and who is
// in it now, with Revoke; Revoke All asks first, inline. A revoke ends the link and closes its guests
// at once (the daemon's `agent-session-share-revoke`); the page only shapes rows and forwards.
// Opened at this card by `#/settings/privacy?focus=card.sharedLinks`. The list is read with the
// section (sectionQueries) and after each revoke; it does not poll.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useLayoutEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import { SHARES_KEY, sharesQuery } from "../sectionQueries";
import { shareDate, sharedLinkRows, type SharedLinkRow } from "../sharedLinks";
import { locale, t } from "../strings";

export function SharedLinksCard({ reveal = false }: { reveal?: boolean }) {
  const store = useStore();
  const queryClient = useQueryClient();
  const query = useQuery(sharesQuery(store));
  const state = query.data ?? null;
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const card = useRef<HTMLElement>(null);
  const drawn = query.isFetched;
  useLayoutEffect(() => {
    if (drawn && reveal) card.current?.scrollIntoView?.({ block: "start" });
  }, [drawn, reveal]);
  const now = Date.now();
  const rows = sharedLinkRows(state, now);
  const revoke = async (ids: string[]) => {
    setBusy(true);
    try {
      setError(await store.revokeShares(ids));
      await queryClient.invalidateQueries({ queryKey: SHARES_KEY });
    } finally {
      setBusy(false);
      setConfirming(false);
    }
  };
  const unavailable = drawn && (state === null || !state.available);
  const confirmTitle = t("settingsPage.sharedLinks.revokeAllTitle");
  return (
    <section className="group" data-card="sharedLinks" id="shared-links" ref={card}>
      <h3 className="group-title">{t("settingsPage.sharedLinks.title")}</h3>
      <div className="rows">
        {unavailable ? (
          <div className="row" data-shared-links-unavailable="">
            <span className="row-help">{t("settingsPage.sharedLinks.unavailable")}</span>
          </div>
        ) : drawn && rows.length === 0 ? (
          <div className="row" data-shared-links-empty="">
            <span className="row-help">{t("settingsPage.sharedLinks.empty")}</span>
          </div>
        ) : (
          <SharedLinksList rows={rows} now={now} busy={busy} onRevoke={(id) => void revoke([id])} />
        )}
      </div>
      {rows.length > 1 &&
        (confirming ? (
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          <div className="accounts-form" data-shared-links-confirm="" role="group" aria-label={confirmTitle}>
            <div className="row-title">{confirmTitle}</div>
            <div className="row-help">{t("settingsPage.sharedLinks.revokeAllBody")}</div>
            <div className="accounts-buttons">
              <Button
                danger
                variant="ghost"
                className="button"
                data-shared-links-action="confirmRevokeAll"
                disabled={busy}
                onClick={() => void revoke(rows.map((row) => row.id))}
              >
                {t("settingsPage.sharedLinks.revokeAll")}
              </Button>
              <Button className="button" data-shared-links-action="cancel" onClick={() => setConfirming(false)}>
                {t("settingsPage.cancel")}
              </Button>
            </div>
          </div>
        ) : (
          <div className="host-footer">
            <Button
              danger
              variant="ghost"
              className="button"
              data-shared-links-action="revokeAll"
              disabled={busy}
              onClick={() => setConfirming(true)}
            >
              {t("settingsPage.sharedLinks.revokeAll")}
            </Button>
          </div>
        ))}
      {error && (
        <div className="row-error" role="alert" data-shared-links-error="">
          {t("settingsPage.sharedLinks.failed", error)}
        </div>
      )}
    </section>
  );
}

/** The kind line: "Link", or "People: 2" when cmux accounts are invited. */
export function sharedLinkKind(row: SharedLinkRow): string {
  return row.kind === "people"
    ? t("settingsPage.sharedLinks.kindPeople", row.invited)
    : t("settingsPage.sharedLinks.kindLink");
}

/** The detail line under the chat's name: kind · shared <date> · ends <date>. */
export function sharedLinkDetail(row: SharedLinkRow, now: number): string {
  const lang = locale();
  return [
    sharedLinkKind(row),
    t("settingsPage.sharedLinks.created", shareDate(row.createdAt, now, lang)),
    t("settingsPage.sharedLinks.expires", shareDate(row.expiresAt, now, lang)),
  ].join(" · ");
}

/** How the list draws (gallery `settings.shared-links-layouts`): `rows`, the shipped one, puts the
 * chat's name over one detail line and the guests, the Settings row shape every other card uses;
 * `table` gives each fact its own column like ChatGPT's Shared links; `compact` is one line per chat. */
export type SharedLinksLayout = "rows" | "table" | "compact";

export function SharedLinksList({
  rows,
  now,
  busy,
  onRevoke,
  layout = "rows",
}: {
  rows: SharedLinkRow[];
  now: number;
  busy: boolean;
  onRevoke: (id: string) => void;
  layout?: SharedLinksLayout;
}) {
  const lang = locale();
  return (
    <>
      {rows.map((row) => {
        const chat = row.chat ?? t("settingsPage.sharedLinks.untitled");
        const revoke = (
          <span className="row-control">
            <Button
              danger
              variant="ghost"
              className="button"
              data-shared-link-action="revoke"
              aria-label={t("settingsPage.sharedLinks.revokeChat", chat)}
              disabled={busy}
              onClick={() => onRevoke(row.id)}
            >
              {t("settingsPage.sharedLinks.revoke")}
            </Button>
          </span>
        );
        const guests = row.guests.length > 0 && (
          <div className="row-help" data-shared-link-guests="">
            {t("settingsPage.sharedLinks.inChat", row.guests.join(", "))}
          </div>
        );
        if (layout === "table") {
          return (
            <div className="row shared-links-table" data-shared-link={row.id} key={row.id}>
              <div className="row-main">
                <div className="row-label">
                  <div className="row-title">{chat}</div>
                  {guests}
                </div>
                <span className="row-help">{sharedLinkKind(row)}</span>
                <span className="row-help">{shareDate(row.createdAt, now, lang)}</span>
                <span className="row-help">{shareDate(row.expiresAt, now, lang)}</span>
                {revoke}
              </div>
            </div>
          );
        }
        if (layout === "compact") {
          return (
            <div className="row" data-shared-link={row.id} key={row.id} title={sharedLinkDetail(row, now)}>
              <div className="row-main">
                <span className="row-label">
                  <span className="row-title">{chat}</span>
                  <span className="row-help"> · {sharedLinkKind(row)}</span>
                </span>
                {revoke}
              </div>
            </div>
          );
        }
        return (
          <div className="row" data-shared-link={row.id} key={row.id}>
            <div className="row-main">
              <div className="row-label">
                <div className="row-title">{chat}</div>
                <div className="row-help" data-shared-link-detail="">
                  {sharedLinkDetail(row, now)}
                </div>
                {guests}
              </div>
              {revoke}
            </div>
          </div>
        );
      })}
    </>
  );
}

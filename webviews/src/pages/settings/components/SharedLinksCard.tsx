// Settings > Privacy and Security > Shared Links (design chat-multiplayer.md 2, "Shared links"): every
// chat this Mac shared by link or by invite, like ChatGPT's Settings > Data controls > Shared links.
// Each row names the chat, what kind of share it is, when it was shared and when it ends, and who is
// in it now, with Revoke; Revoke All asks first, inline. A revoke ends the link and closes its guests
// at once (the daemon's `agent-session-share-revoke`); the page only shapes rows and forwards.
// Opened at this card by `#/settings/privacy?focus=card.sharedLinks`. The list is read with the
// section (sectionQueries) and after each revoke; it does not poll.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Fragment, memo, useCallback, useContext, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useStableHandlers } from "../../../agent-session/acpmux/stableHandlers";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import { SHARES_KEY, sharesQuery } from "../sectionQueries";
import { CardBusy, useCardWindow, windowGap, type CardWindow } from "../cardWindow";
import { keepUnchangedLinks, shareDate, sharedLinkRows, startOfDay, type SharedLinkRow } from "../sharedLinks";
import { locale, t } from "../strings";
import { WithFacts } from "../../../agent-session/acpmux/chips/FactsHoverCard";

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
  // The rows change with the list the host sends, not with the card's own state (busy, confirming):
  // a share that ends drops at the next read (the list is read with the section and after each revoke).
  const now = Date.now();
  const [kept, setKept] = useState(() => ({ state, rows: sharedLinkRows(state, now) }));
  let rows = kept.rows;
  if (kept.state !== state) {
    rows = keepUnchangedLinks(kept.rows, sharedLinkRows(state, now));
    setKept({ state, rows });
  }
  const keys = useMemo(() => rows.map((row) => row.id), [rows]);
  // A row with guests draws one more line.
  const rowWindow = useCardWindow(keys, SHARED_LINK_ESTIMATE, (index) => (rows[index]?.guests.length ? "guests" : ""));
  // The route's reveal waits for the window (cardWindow.ts `ready`): the card and its rows' room are
  // drawn, and the window's start no longer moves the page.
  // The list's ref apart from the window: the compiler takes a property set as a `ref` for a ref
  // object and every other read of the window for a ref read during render.
  const { list: rowList, ready } = rowWindow;
  useLayoutEffect(() => {
    if (drawn && reveal && ready) card.current?.scrollIntoView?.({ block: "start" });
  }, [drawn, reveal, ready]);
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
  const { onRevoke } = useStableHandlers({ onRevoke: (id: string) => void revoke([id]) });
  const unavailable = drawn && (state === null || !state.available);
  const listing = !unavailable && rows.length > 0;
  const confirmTitle = t("settingsPage.sharedLinks.revokeAllTitle");
  return (
    <section className="group" data-card="sharedLinks" id="shared-links" ref={card}>
      <h3 className="group-title">{t("settingsPage.sharedLinks.title")}</h3>
      <div
        className="rows"
        ref={rowList}
        role={listing ? "list" : undefined}
        style={{ paddingBottom: rowWindow.padBottom }}
        onFocus={rowWindow.onFocus}
        onBlur={rowWindow.onBlur}
      >
        {unavailable ? (
          <div className="row" data-shared-links-unavailable="">
            <span className="row-help">{t("settingsPage.sharedLinks.unavailable")}</span>
          </div>
        ) : drawn && rows.length === 0 ? (
          <div className="row" data-shared-links-empty="">
            <span className="row-help">{t("settingsPage.sharedLinks.empty")}</span>
          </div>
        ) : (
          <SharedLinksList rows={rows} now={now} busy={busy} onRevoke={onRevoke} rowWindow={rowWindow} />
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

/** A row's height before one is measured (the `rows` layout: title, detail and guests). */
const SHARED_LINK_ESTIMATE = 72;

/**
 * The rows, as memo rows: each takes its own share, the start of today (all its dates need of the
 * clock) and one stable `onRevoke`, so a revoke, a read that changed one share or a new reading of
 * the clock draws only the rows it changed. `busy` goes through CardBusy to the Revoke buttons
 * alone, so a revoke in flight draws no row again. With `rowWindow` (the card), only the rows near the
 * viewport mount; without (the gallery), every row.
 */
export function SharedLinksList({
  rows,
  now,
  busy,
  onRevoke,
  layout = "rows",
  rowWindow,
}: {
  rows: SharedLinkRow[];
  now: number;
  busy: boolean;
  onRevoke: (id: string) => void;
  layout?: SharedLinksLayout;
  rowWindow?: CardWindow;
}) {
  const today = startOfDay(now);
  const items = rowWindow?.items ?? rows.map((row, index) => ({ index, key: row.id, gap: 0 }));
  return (
    <CardBusy.Provider value={busy}>
      {items.map(({ index, key, gap }) => (
        <Fragment key={key}>
          {windowGap(gap)}
          <SharedLinkItem
            row={rows[index]!}
            index={index}
            count={rows.length}
            today={today}
            layout={layout}
            onRevoke={onRevoke}
            measure={rowWindow?.measure}
          />
        </Fragment>
      ))}
    </CardBusy.Provider>
  );
}

const SharedLinkItem = memo(function SharedLinkItem({
  row,
  index,
  count,
  today,
  layout,
  onRevoke,
  measure,
}: {
  row: SharedLinkRow;
  index: number;
  count: number;
  today: number;
  layout: SharedLinksLayout;
  onRevoke: (id: string) => void;
  measure?: (node: HTMLElement | null) => void;
}) {
  const lang = locale();
  const chat = row.chat ?? t("settingsPage.sharedLinks.untitled");
  // The compact row's tooltip anchor and the list's measure are both refs on one element.
  const factsRef = useRef<((node: HTMLElement | null) => void) | null>(null);
  const compactRef = useCallback(
    (node: HTMLElement | null) => {
      factsRef.current?.(node);
      measure?.(node);
    },
    [measure],
  );
  const place = {
    ref: measure,
    "data-index": index,
    role: "listitem",
    "aria-posinset": index + 1,
    "aria-setsize": count,
  };
  const revoke = (
    <span className="row-control">
      <RevokeButton id={row.id} chat={chat} onRevoke={onRevoke} />
    </span>
  );
  const guests = row.guests.length > 0 && (
    <div className="row-help" data-shared-link-guests="">
      {t("settingsPage.sharedLinks.inChat", row.guests.join(", "))}
    </div>
  );
  if (layout === "table") {
    return (
      <div className="row shared-links-table" data-shared-link={row.id} {...place}>
        <div className="row-main">
          <div className="row-label">
            <div className="row-title">{chat}</div>
            {guests}
          </div>
          <span className="row-help">{sharedLinkKind(row)}</span>
          <span className="row-help">{shareDate(row.createdAt, today, lang)}</span>
          <span className="row-help">{shareDate(row.expiresAt, today, lang)}</span>
          {revoke}
        </div>
      </div>
    );
  }
  if (layout === "compact") {
    return (
      <WithFacts facts={[{ value: sharedLinkDetail(row, today) }]}>
        {(facts) => {
          factsRef.current = facts.ref;
          return (
            <div {...facts} {...place} ref={compactRef} className="row" data-shared-link={row.id}>
              <div className="row-main">
                <span className="row-label">
                  <span className="row-title">{chat}</span>
                  <span className="row-help"> · {sharedLinkKind(row)}</span>
                </span>
                {revoke}
              </div>
            </div>
          );
        }}
      </WithFacts>
    );
  }
  return (
    <div className="row" data-shared-link={row.id} {...place}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{chat}</div>
          <div className="row-help" data-shared-link-detail="">
            {sharedLinkDetail(row, today)}
          </div>
          {guests}
        </div>
        {revoke}
      </div>
    </div>
  );
});

/** A row's Revoke, disabled while a revoke is in flight: it reads CardBusy, so the row around it
 * does not draw again. */
function RevokeButton({ id, chat, onRevoke }: { id: string; chat: string; onRevoke: (id: string) => void }) {
  return (
    <Button
      danger
      variant="ghost"
      className="button"
      data-shared-link-action="revoke"
      aria-label={t("settingsPage.sharedLinks.revokeChat", chat)}
      disabled={useContext(CardBusy)}
      onClick={() => onRevoke(id)}
    >
      {t("settingsPage.sharedLinks.revoke")}
    </Button>
  );
}

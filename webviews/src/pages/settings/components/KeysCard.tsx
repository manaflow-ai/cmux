// Settings > Keys (design/settings-keys.md): the keys agents keep on this Mac and the keys they ask
// the person for. Leo, 2026-11-15: "letting agents safely write keys and store them or enter them
// jnto whatever". An agent's `cmux keys request NAME` lands here as a request with what it is for,
// who asked and the sites it may go to; the person types the value once, Store sends it to the
// app, which pipes it to `cmux keys put` on stdin, and the field empties as it is sent. Below,
// every key `cmux keys ls` lists: what it is, where it may go, where it went, who added it and when
// it ends, never a value, with Revoke (asks first, inline). Opened at this card by
// `#/settings/keys` (the request's notification). The list is read with the section
// (sectionQueries), after each gesture and on the host's `cmux.settings.keys.changed`; no polling.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Fragment, memo, useLayoutEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { useStableHandlers } from "../../../agent-session/acpmux/stableHandlers";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import { useCardWindow, windowGap } from "../cardWindow";
import { keepUnchangedKeys, keyDate, keyRequestRows, keyRows, type KeyRequestRow, type KeyRow } from "../keys";
import { startOfDay } from "../sharedLinks";
import { KEYS_KEY, keysQuery } from "../sectionQueries";
import { locale, t } from "../strings";

export function KeysCard({ reveal = false }: { reveal?: boolean }) {
  const store = useStore();
  const queryClient = useQueryClient();
  const query = useQuery(keysQuery(store));
  const state = query.data ?? null;
  const card = useRef<HTMLElement>(null);
  const requestsCard = useRef<HTMLElement>(null);
  const drawn = query.isFetched;
  const requests = keyRequestRows(state);
  const asking = requests.length > 0;
  const [now] = useState(() => Date.now());
  // The rows change with the list the host sends; a key whose record did not change keeps its row.
  const [kept, setKept] = useState(() => ({ state, rows: keyRows(state, now) }));
  let rows = kept.rows;
  if (kept.state !== state) {
    rows = keepUnchangedKeys(kept.rows, keyRows(state, now));
    setKept({ state, rows });
  }
  const keys = useMemo(() => rows.map((row) => row.id), [rows]);
  // A row draws its purpose and who added it only when the record has them.
  // Rows whose Revoke is asking first: they stay mounted while it asks, wherever the page scrolls.
  const [confirmOpen, setConfirmOpen] = useState<ReadonlySet<string>>(() => new Set());
  const rowWindow = useCardWindow(
    keys,
    KEY_ESTIMATE,
    (index) => {
      const row = rows[index];
      return row ? `${row.purpose ? "p" : ""}${keyAddedBy(row) ? "a" : ""}` : "";
    },
    confirmOpen,
  );
  // The deep link (a request's notification) lands on the requests when any wait, else on the keys,
  // once the keys' window is drawn (cardWindow.ts `ready`).
  // The list's ref apart from the window: the compiler takes a property set as a `ref` for a ref
  // object and every other read of the window for a ref read during render.
  const { list: rowList, ready } = rowWindow;
  useLayoutEffect(() => {
    if (drawn && reveal && ready) (asking ? requestsCard : card).current?.scrollIntoView?.({ block: "start" });
  }, [drawn, reveal, asking, ready]);
  // A row's dates need only whether a date is today.
  const today = startOfDay(now);
  const refresh = () => queryClient.invalidateQueries({ queryKey: KEYS_KEY });
  const { onRevoke, onConfirming } = useStableHandlers({
    onConfirming: (id: string, open: boolean) =>
      setConfirmOpen((current) => {
        if (current.has(id) === open) return current;
        const next = new Set(current);
        if (open) next.add(id);
        else next.delete(id);
        return next;
      }),
    onRevoke: async (id: string) => {
      const error = await store.revokeKey(id);
      await refresh();
      return error;
    },
  });
  const unavailable = drawn && (state === null || state.available === false);
  const listing = !unavailable && rows.length > 0;
  return (
    <>
      {asking && (
        <section className="group" data-card="keyRequests" ref={requestsCard}>
          <h3 className="group-title">{t("settingsPage.keys.requestsTitle")}</h3>
          <div className="rows">
            {requests.map((request) => (
              <KeyRequestForm
                key={request.id}
                request={request}
                onAnswer={async (value) => {
                  const error = await store.answerKeyRequest(request.id, value);
                  if (error === null) await refresh();
                  return error;
                }}
                onDecline={async () => {
                  const error = await store.declineKeyRequest(request.id);
                  await refresh();
                  return error;
                }}
              />
            ))}
          </div>
        </section>
      )}
      <section className="group" data-card="keys" id="keys" ref={card}>
        <h3 className="group-title">{t("settingsPage.keys.title")}</h3>
        <div
          className="rows"
          ref={rowList}
          role={listing ? "list" : undefined}
          style={{ paddingBottom: rowWindow.padBottom }}
          onFocus={rowWindow.onFocus}
          onBlur={rowWindow.onBlur}
        >
          {unavailable ? (
            <div className="row" data-keys-unavailable="">
              <span className="row-help">{t("settingsPage.keys.unavailable")}</span>
            </div>
          ) : drawn && rows.length === 0 ? (
            <div className="row" data-keys-empty="">
              <span className="row-help">
                <WithCode text={t("settingsPage.keys.empty")} code="cmux keys put NAME" />
              </span>
            </div>
          ) : (
            rowWindow.items.map(({ index, key, gap }) => (
              <Fragment key={key}>
                {windowGap(gap)}
                <KeyRowView
                  row={rows[index]!}
                  index={index}
                  count={rows.length}
                  today={today}
                  onRevoke={onRevoke}
                  onConfirming={onConfirming}
                  measure={rowWindow.measure}
                />
              </Fragment>
            ))
          )}
        </div>
      </section>
    </>
  );
}

/** `text` with its `%@` drawn as `code` in the page's mono face. */
function WithCode({ text, code }: { text: string; code: string }) {
  const at = text.indexOf("%@");
  if (at < 0) return <>{text}</>;
  return (
    <>
      {text.slice(0, at)}
      <code className="keys-code">{code}</code>
      {text.slice(at + 2)}
    </>
  );
}

/** One waiting request: what it is for, who asked, the sites it may go to, a private field, Store
 * and Decline. The typed value lives in this form's state only until Store sends it; a send the
 * host refused puts it back so the person need not type it again. */
function KeyRequestForm({
  request,
  onAnswer,
  onDecline,
}: {
  request: KeyRequestRow;
  onAnswer: (value: string) => Promise<string | null>;
  onDecline: () => Promise<string | null>;
}) {
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const store = (event: FormEvent) => {
    event.preventDefault();
    if (!value || busy) return;
    const sent = value;
    setValue("");
    setError(null);
    setBusy(true);
    void onAnswer(sent).then(
      (refused) => {
        setBusy(false);
        if (refused === null) return;
        setError(t("settingsPage.keys.storeFailed", refused));
        setValue((current) => current || sent);
      },
      () => {
        setBusy(false);
        setValue((current) => current || sent);
      },
    );
  };
  const decline = () => {
    setBusy(true);
    setValue("");
    void onDecline().then((refused) => {
      setBusy(false);
      setError(refused === null ? null : t("settingsPage.keys.storeFailed", refused));
    });
  };
  return (
    <form className="row keys-request" data-key-request={request.id} onSubmit={store}>
      <div className="row-label">
        <div className="row-title">
          <code className="keys-name">{request.name}</code>
        </div>
        {request.purpose && (
          // The agent's own words, as it sent them: a value the person may copy, not a description.
          <div className="row-help selectable keys-purpose" data-key-request-purpose="">
            {request.purpose}
          </div>
        )}
        {request.requester && (
          <div className="row-help" data-key-request-detail="">
            {t("settingsPage.keys.askedBy", request.requester)}
          </div>
        )}
        {request.hosts.length > 0 && (
          <div className="row-help selectable" data-key-request-hosts="">
            {t("settingsPage.keys.forHosts", request.hosts.join(", "))}
          </div>
        )}
      </div>
      <div className="keys-answer">
        <Input
          className="field keys-field"
          type="password"
          autoComplete="off"
          spellCheck={false}
          aria-label={t("settingsPage.keys.field", request.name)}
          placeholder={t("settingsPage.keys.placeholder")}
          value={value}
          aria-invalid={error !== null}
          data-key-request-field=""
          onChange={(event) => {
            setError(null);
            setValue(event.target.value);
          }}
        />
        <Button
          type="submit"
          variant="solid"
          className="button"
          data-key-request-action="store"
          disabled={!value || busy}
        >
          {t("settingsPage.keys.store")}
        </Button>
        <Button type="button" className="button" data-key-request-action="decline" disabled={busy} onClick={decline}>
          {t("settingsPage.keys.decline")}
        </Button>
      </div>
      <div className="row-help">{t("settingsPage.keys.private")}</div>
      {error && (
        <div className="row-error" role="alert" data-key-request-error="">
          {error}
        </div>
      )}
    </form>
  );
}

const tones = { live: "success", expired: "attention", revoked: "neutral" } as const;

/** A key's facts, values the person may copy: where it may go · where it went · when it ends. */
export function keyFacts(row: KeyRow, now: number): string {
  return [
    row.hosts.length > 0 ? t("settingsPage.keys.forHosts", row.hosts.join(", ")) : t("settingsPage.keys.anySite"),
    row.places.length > 0 ? t("settingsPage.keys.usedIn", row.places.join(", ")) : t("settingsPage.keys.notUsed"),
    row.expiresAt === null
      ? t("settingsPage.keys.noExpiry")
      : t("settingsPage.keys.expires", keyDate(row.expiresAt, now, locale())),
  ].join(" · ");
}

/** Who added a key, and who asked for it when that was someone else; null when the record names nobody. */
export function keyAddedBy(row: KeyRow): string | null {
  const added = row.askedBy && row.askedBy !== row.by ? `${row.by ?? ""} (${row.askedBy})`.trim() : row.by;
  return added ? t("settingsPage.keys.addedBy", added) : null;
}

/** A key row's height before one is measured (title, purpose, facts and who added it). */
const KEY_ESTIMATE = 96;

/** One key, a memo row: its own record, the start of today (all its dates need of the clock) and one
 * stable `onRevoke`, so a read that changed another key, or a revoke, leaves it be. */
const KeyRowView = memo(function KeyRowView({
  row,
  index,
  count,
  today,
  onRevoke,
  onConfirming,
  measure,
}: {
  row: KeyRow;
  index: number;
  count: number;
  today: number;
  onRevoke: (id: string) => Promise<string | null>;
  /** The row's Revoke opened or closed its confirmation. */
  onConfirming: (id: string, open: boolean) => void;
  measure: (node: HTMLElement | null) => void;
}) {
  const [confirming, setConfirmingState] = useState(false);
  const setConfirming = (open: boolean) => {
    setConfirmingState(open);
    onConfirming(row.id, open);
  };
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const revoke = async () => {
    setBusy(true);
    const refused = await onRevoke(row.id);
    setBusy(false);
    setConfirming(false);
    setError(refused === null ? null : t("settingsPage.keys.revokeFailed", refused));
  };
  const state = t(
    row.state === "live"
      ? "settingsPage.keys.stateLive"
      : row.state === "expired"
        ? "settingsPage.keys.stateExpired"
        : "settingsPage.keys.stateRevoked",
  );
  const confirmTitle = t("settingsPage.keys.revokeTitle", row.label);
  const addedBy = keyAddedBy(row);
  return (
    <div
      className="row"
      data-key={row.id}
      data-key-state={row.state}
      ref={measure}
      data-index={index}
      // A list item by role: the card's `.rows` stays a div, the shape every Settings card has.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listitem"
      aria-posinset={index + 1}
      aria-setsize={count}
    >
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">
            {row.label}
            {row.name && (
              <>
                {" "}
                <code className="keys-name">{row.name}</code>
              </>
            )}
          </div>
          {row.purpose && <div className="row-help selectable keys-purpose">{row.purpose}</div>}
          <div className="row-help selectable" data-key-detail="">
            {keyFacts(row, today)}
          </div>
          {addedBy && (
            <div className="row-help" data-key-added="">
              {addedBy}
            </div>
          )}
        </div>
        <span className="row-control keys-control">
          <span className="accounts-status devices-status" data-tone={tones[row.state]} data-key-status="">
            <span className="accounts-dot" aria-hidden="true" />
            {state}
          </span>
          {row.state !== "revoked" && !confirming && (
            <Button
              danger
              variant="ghost"
              className="button"
              data-key-action="revoke"
              aria-label={t("settingsPage.keys.revokeKey", row.label)}
              disabled={busy}
              onClick={() => setConfirming(true)}
            >
              {t("settingsPage.keys.revoke")}
            </Button>
          )}
        </span>
      </div>
      {confirming && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="accounts-form" data-key-confirm="" role="group" aria-label={confirmTitle}>
          <div className="row-title">{confirmTitle}</div>
          <div className="row-help">
            {t(row.provider === "local" ? "settingsPage.keys.revokeBodyLocal" : "settingsPage.keys.revokeBodyProvider")}
          </div>
          <div className="accounts-buttons">
            <Button
              danger
              variant="ghost"
              className="button"
              data-key-action="confirmRevoke"
              disabled={busy}
              onClick={() => void revoke()}
            >
              {t("settingsPage.keys.revoke")}
            </Button>
            <Button className="button" data-key-action="cancel" onClick={() => setConfirming(false)}>
              {t("settingsPage.cancel")}
            </Button>
          </div>
        </div>
      )}
      {error && (
        <div className="row-error" role="alert" data-key-error="">
          {error}
        </div>
      )}
    </div>
  );
});

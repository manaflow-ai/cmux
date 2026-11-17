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
import { useLayoutEffect, useRef, useState, type FormEvent } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import { keyDate, keyRequestRows, keyRows, type KeyRequestRow, type KeyRow } from "../keys";
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
  // The deep link (a request's notification) lands on the requests when any wait, else on the keys.
  useLayoutEffect(() => {
    if (drawn && reveal) (asking ? requestsCard : card).current?.scrollIntoView?.({ block: "start" });
  }, [drawn, reveal, asking]);
  const [now] = useState(() => Date.now());
  const rows = keyRows(state, now);
  const refresh = () => queryClient.invalidateQueries({ queryKey: KEYS_KEY });
  const unavailable = drawn && (state === null || state.available === false);
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
        <div className="rows">
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
            rows.map((row) => (
              <KeyRowView
                key={row.id}
                row={row}
                now={now}
                onRevoke={async () => {
                  const error = await store.revokeKey(row.id);
                  await refresh();
                  return error;
                }}
              />
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

function KeyRowView({ row, now, onRevoke }: { row: KeyRow; now: number; onRevoke: () => Promise<string | null> }) {
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const revoke = async () => {
    setBusy(true);
    const refused = await onRevoke();
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
    <div className="row" data-key={row.id} data-key-state={row.state}>
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
            {keyFacts(row, now)}
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
}

// The Mobile Pairing page (palette "Open Mobile Pairing", Settings > Accounts, the composer's
// machine picker): three steps to a phone that reaches this Mac (sign in, iPhone connections, the
// iPhone host), the button for the one missing step, then how to connect, the phones asking to
// connect (Allow, Don't Allow) and the account's phones. A phone signed in to the same account
// already lists this Mac, so the host's QR code (a one-time pre-approval that skips the Allow
// prompt) stays behind "Pair another way" until the person asks for it.
import { useEffect, useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import type { MobilePairingStore } from "./store";
import type { MobilePairingStatus, PairingHost, PairingQR, PairingState } from "./types";

const ORDER: PairingState[] = ["signedOut", "accessOff", "preparing", "ready"];

export function MobilePairingPage({ store, strings }: { store: MobilePairingStore; strings: Strings }) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const status = snapshot.status;
  const expiresAt = status?.qr?.expiresAt;

  // A shown code is replaced when it expires.
  useEffect(() => {
    if (expiresAt === undefined) return;
    const timer = setTimeout(() => void store.refreshIfExpired(), Math.max(0, expiresAt - Date.now()) + 250);
    return () => clearTimeout(timer);
  }, [store, expiresAt]);

  return (
    <div className="pairing">
      <header className="pairing-header">
        <h1 className="pairing-title">{strings.t("mobilePairing.page.title")}</h1>
        <p className="pairing-subtitle">{strings.t("mobilePairing.page.subtitle")}</p>
      </header>
      {snapshot.unavailable ? (
        <p className="pairing-message">{strings.t("mobilePairing.page.unavailable")}</p>
      ) : !status ? (
        snapshot.failed ? (
          <Failed store={store} strings={strings} />
        ) : (
          <p className="pairing-message pairing-muted">{strings.t("mobilePairing.page.loading")}</p>
        )
      ) : (
        <>
          <Steps status={status} strings={strings} />
          <Content status={status} store={store} strings={strings} />
          {snapshot.failed && <p className="pairing-message">{strings.t("mobilePairing.page.loadFailed")}</p>}
        </>
      )}
    </div>
  );
}

function Failed({ store, strings }: { store: MobilePairingStore; strings: Strings }) {
  return (
    <div className="pairing-panel">
      <p className="pairing-message">{strings.t("mobilePairing.page.loadFailed")}</p>
      <button type="button" className="pairing-button" onClick={() => void store.refresh()}>
        {strings.t("mobilePairing.page.retry")}
      </button>
    </div>
  );
}

function Steps({ status, strings }: { status: MobilePairingStatus; strings: Strings }) {
  // A failed listener sits where preparing does: the first two steps are done.
  const reached = ORDER.indexOf(status.state === "failed" ? "preparing" : status.state);
  const steps = [
    {
      key: "account",
      label:
        reached > 0 && status.account
          ? strings.format("mobilePairing.page.step.accountDone", status.account)
          : strings.t("mobilePairing.page.step.account"),
    },
    {
      key: "access",
      label:
        reached > 1 ? strings.t("mobilePairing.page.step.accessDone") : strings.t("mobilePairing.page.step.access"),
    },
    {
      key: "listener",
      label:
        reached > 2 ? strings.t("mobilePairing.page.step.listenerDone") : strings.t("mobilePairing.page.step.listener"),
    },
  ];
  return (
    <ol className="pairing-steps" aria-label={strings.t("mobilePairing.page.steps")}>
      {steps.map((step, index) => {
        const state = index < reached ? "done" : index === reached ? "current" : "todo";
        return (
          <li
            key={step.key}
            className={`pairing-step is-${state}`}
            aria-current={state === "current" ? "step" : undefined}
          >
            <span className="pairing-step-mark" aria-hidden="true">
              {state === "done" ? "✓" : String(index + 1)}
            </span>
            <span className="pairing-step-label">{step.label}</span>
          </li>
        );
      })}
    </ol>
  );
}

type Props = { status: MobilePairingStatus; store: MobilePairingStore; strings: Strings };

function Content({ status, store, strings }: Props) {
  switch (status.state) {
    case "signedOut":
      return (
        <div className="pairing-panel">
          <p className="pairing-body">{strings.t("mobilePairing.page.signedOut.body")}</p>
          <button
            type="button"
            className="pairing-button is-primary"
            data-action="sign-in"
            onClick={() => void store.signIn()}
          >
            {strings.t("mobilePairing.page.signIn")}
          </button>
        </div>
      );
    case "accessOff":
      return (
        <div className="pairing-panel">
          <p className="pairing-body">{strings.t("mobilePairing.page.accessOff.body")}</p>
          <div className="pairing-actions">
            <button
              type="button"
              className="pairing-button is-primary"
              data-action="allow"
              onClick={() => void store.setAllowed(true)}
            >
              {strings.t("mobilePairing.page.allow")}
            </button>
            <SettingsButton store={store} strings={strings} />
          </div>
        </div>
      );
    case "preparing":
      return (
        <div className="pairing-panel">
          <output className="pairing-body pairing-muted">{strings.t("mobilePairing.page.preparing")}</output>
          <Footer status={status} store={store} strings={strings} />
        </div>
      );
    case "failed":
      return (
        <div className="pairing-panel">
          <p className="pairing-body">{strings.t("mobilePairing.page.failed.body")}</p>
          {status.failure && <p className="pairing-failure-detail">{status.failure}</p>}
          <Footer status={status} store={store} strings={strings} />
        </div>
      );
    case "ready":
      return (
        <div className="pairing-panel pairing-ready">
          {status.qr && status.account ? (
            <p className="pairing-body pairing-open">
              {strings.format("mobilePairing.page.ready.open", status.account)}
            </p>
          ) : (
            status.host?.how && <p className="pairing-body pairing-how">{status.host.how}</p>
          )}
          {status.qr && <PairAnotherWay qr={status.qr} strings={strings} />}
          <Footer status={status} store={store} strings={strings} />
        </div>
      );
  }
}

/**
 * The QR code, folded away: a phone on the same account already lists this Mac. Open, it pairs a
 * phone from the camera without the Allow prompt (and moves it to this Mac's team); a new code
 * from the host keeps it open.
 */
function PairAnotherWay({ qr, strings }: { qr: PairingQR; strings: Strings }) {
  const [shown, setShown] = useState(false);
  return (
    <div className="pairing-another">
      <button
        type="button"
        className="pairing-link"
        data-action="pair-another-way"
        aria-expanded={shown}
        aria-controls="pairing-code"
        onClick={() => setShown((open) => !open)}
      >
        {strings.t(shown ? "mobilePairing.page.hideCode" : "mobilePairing.page.pairAnotherWay")}
      </button>
      {shown && (
        <figure id="pairing-code" className="pairing-code">
          <img className="pairing-qr" src={qr.image} alt={strings.t("mobilePairing.page.qrAlt")} />
          <figcaption className="pairing-body">{strings.t("mobilePairing.page.ready.scan")}</figcaption>
        </figure>
      )}
    </div>
  );
}

function Footer({ status, store, strings }: Props) {
  return (
    <div className="pairing-footer">
      {status.host && <Requests host={status.host} store={store} />}
      <p className="pairing-muted">{strings.format("mobilePairing.page.macName", status.macName)}</p>
      {status.host?.status && <p className="pairing-muted pairing-host-status">{status.host.status}</p>}
      {status.host && <Phones host={status.host} />}
      <div className="pairing-actions">
        <button
          type="button"
          className="pairing-button"
          data-action="turn-off"
          onClick={() => void store.setAllowed(false)}
        >
          {strings.t("mobilePairing.page.turnOff")}
        </button>
        <SettingsButton store={store} strings={strings} />
      </div>
    </div>
  );
}

/** Phones asking to connect: the person's Allow or Don't Allow answers each, as the prompt does. */
function Requests({ host, store }: { host: PairingHost; store: MobilePairingStore }) {
  if (host.pending.length === 0 && !host.blocked) return null;
  return (
    <section className="pairing-requests" aria-label={host.pendingTitle}>
      {host.pendingTitle && host.pending.length > 0 && <h2 className="pairing-section-title">{host.pendingTitle}</h2>}
      {host.pending.map((request) => (
        <div key={request.id} className="pairing-request" data-request={request.id}>
          <p className="pairing-row-title">{request.title}</p>
          <p className="pairing-muted pairing-row-subtitle">{request.subtitle}</p>
          <div className="pairing-actions">
            <button
              type="button"
              className="pairing-button"
              data-action="deny"
              onClick={() => void store.answerPair(request.id, false)}
            >
              {host.denyTitle}
            </button>
            <button
              type="button"
              className="pairing-button is-primary"
              data-action="allow-phone"
              onClick={() => void store.answerPair(request.id, true)}
            >
              {host.allowTitle}
            </button>
          </div>
        </div>
      ))}
      {host.blocked && <p className="pairing-muted">{host.blocked}</p>}
    </section>
  );
}

/** The account's phones, each with its live link if one is up. */
function Phones({ host }: { host: PairingHost }) {
  return (
    <section className="pairing-phones" aria-label={host.phonesTitle}>
      {host.phonesTitle && <h2 className="pairing-section-title">{host.phonesTitle}</h2>}
      {host.phonesError && <p className="pairing-muted pairing-phones-error">{host.phonesError}</p>}
      {host.phones.length === 0 ? (
        !host.phonesError && host.phonesEmpty && <p className="pairing-muted">{host.phonesEmpty}</p>
      ) : (
        <ul className="pairing-phone-list">
          {host.phones.map((phone) => (
            <li key={phone.id} className={`pairing-phone${phone.connected ? " is-connected" : ""}`}>
              <span className="pairing-row-title">{phone.title}</span>
              <span className="pairing-muted pairing-row-subtitle">{phone.subtitle}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function SettingsButton({ store, strings }: { store: MobilePairingStore; strings: Strings }) {
  return (
    <button type="button" className="pairing-button" data-action="settings" onClick={() => void store.openAccounts()}>
      {strings.t("mobilePairing.page.settings")}
    </button>
  );
}

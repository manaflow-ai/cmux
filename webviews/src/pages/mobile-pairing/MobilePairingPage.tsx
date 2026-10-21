// The Mobile Pairing page (palette "Open Mobile Pairing"): three steps to a phone that reaches this
// Mac (sign in, phone access, the listener), the button for the one missing step, and once the Mac
// is reachable a QR code the iPhone camera opens in cmux.
import { useEffect, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import type { MobilePairingStore } from "./store";
import type { MobilePairingStatus, PairingState } from "./types";

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
          {status.qr && (
            <figure className="pairing-code">
              <img className="pairing-qr" src={status.qr.image} alt={strings.t("mobilePairing.page.qrAlt")} />
              <figcaption className="pairing-body">{strings.t("mobilePairing.page.ready.scan")}</figcaption>
            </figure>
          )}
          {status.account && (
            <p className="pairing-body">{strings.format("mobilePairing.page.ready.list", status.account)}</p>
          )}
          <Footer status={status} store={store} strings={strings} />
        </div>
      );
  }
}

function Footer({ status, store, strings }: Props) {
  return (
    <div className="pairing-footer">
      <p className="pairing-muted">{strings.format("mobilePairing.page.macName", status.macName)}</p>
      <p className="pairing-muted pairing-connected">
        {strings.format(
          "mobilePairing.page.connected",
          new Intl.NumberFormat(strings.language).format(status.connectedPhones),
        )}
      </p>
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

function SettingsButton({ store, strings }: { store: MobilePairingStore; strings: Strings }) {
  return (
    <button type="button" className="pairing-button" data-action="settings" onClick={() => void store.openAccounts()}>
      {strings.t("mobilePairing.page.settings")}
    </button>
  );
}

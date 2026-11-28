// The CodeRouter page: status (works signed out), this Mac's providers with Connect and Sign In
// Again, the accounts CodeRouter holds, and API keys (not available until the ops exist). Account
// rows show redacted labels and opaque handles only; the host never sends an email or a secret.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import type { CodeRouterStore } from "./store";
import type { ProviderRow } from "./types";

const PROVIDER_STATUS: Record<string, string> = {
  signed_in: "provider.signedIn",
  expired: "provider.expired",
  missing: "provider.missing",
  unknown: "provider.unknown",
};

export function CodeRouterPage({ store, strings }: { store: CodeRouterStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  if (snap.connection === "disconnected" && !snap.status) return <div className="cr-empty">{t("disconnected")}</div>;
  const signedIn = snap.status?.signed_in === true;
  return (
    <div className="cr-page">
      <header className="cr-header">
        <div className="cr-title-row">
          <h1 className="cr-title">{t("page.title")}</h1>
          <span className={`cr-status${signedIn ? " ok" : ""}`}>
            <span className="cr-dot" aria-hidden="true" />
            {snap.status ? t(signedIn ? "status.signedIn" : "status.signedOut") : ""}
          </span>
          {snap.status && !signedIn && (
            <button type="button" className="cr-button primary" onClick={() => void store.signIn()}>
              {t("action.signIn")}
            </button>
          )}
          <button type="button" className="cr-button" onClick={() => void store.refresh()}>
            {t("action.refresh")}
          </button>
        </div>
        <p className="cr-subtitle">{t("page.subtitle")}</p>
        {snap.error && <output className="cr-error selectable">{snap.error}</output>}
      </header>
      <div className="cr-scroll">
        <section className="cr-section">
          <h2>{t("section.thisMac")}</h2>
          <ul className="cr-list">
            {snap.providers.map((row) => (
              <ProviderItem key={row.provider} row={row} signedIn={signedIn} store={store} strings={strings} />
            ))}
          </ul>
        </section>
        <section className="cr-section">
          <h2>{t("section.linked")}</h2>
          {!signedIn ? (
            <p className="cr-linked-empty cr-muted">{t("linked.signedOut")}</p>
          ) : snap.linked.length === 0 ? (
            <p className="cr-linked-empty cr-muted">{t("linked.none")}</p>
          ) : (
            <ul className="cr-list">
              {snap.linked.map((account) => (
                <li key={account.id} className="cr-linked-row">
                  <span className="cr-linked-label selectable">{account.label}</span>
                  <span className="cr-muted">{account.state}</span>
                  {account.visibility && (
                    <span className="cr-badge">
                      {t(account.visibility === "team" ? "visibility.team" : "visibility.private")}
                    </span>
                  )}
                </li>
              ))}
            </ul>
          )}
        </section>
        <section className="cr-section cr-keys">
          <h2>{t("section.keys")}</h2>
          <p className="cr-muted">{t("unavailable")}</p>
        </section>
      </div>
    </div>
  );
}

function ProviderItem({
  row,
  signedIn,
  store,
  strings,
}: {
  row: ProviderRow;
  signedIn: boolean;
  store: CodeRouterStore;
  strings: Strings;
}) {
  const { t } = strings;
  const status = row.status ? PROVIDER_STATUS[row.status] : undefined;
  const linked = row.linked.length > 0;
  return (
    <li className="cr-provider">
      <span className="cr-provider-name">{row.name}</span>
      <span className="cr-muted selectable">
        {[row.plan ?? row.label, status && t(status)].filter(Boolean).join(" · ")}
      </span>
      <span className="cr-provider-actions">
        {row.status === "expired" && (
          <button type="button" className="cr-button" onClick={() => void store.reauthenticate(row.provider)}>
            {t("action.reauthenticate")}
          </button>
        )}
        {signedIn && row.can_connect && (
          <button
            type="button"
            className={`cr-button${linked ? "" : " primary"}`}
            onClick={() => void store.connect(row.provider, row.name)}
          >
            {t("action.connect")}
          </button>
        )}
      </span>
    </li>
  );
}

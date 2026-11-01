// The Cloud page (plans/cmux-next/cloud-app.md L7, cloud-parity.md "cmux-next UI mapping"). State
// lives in `CloudStore`; this file only renders it and turns plain keys and clicks into intents.
// Cmd and Ctrl chords never reach a page handler (`plain`): the app's key dispatcher owns them.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { useLasting } from "../../ui/lasting";
import { AccountPanel } from "./AccountPanel";
import { CreateSheet } from "./CreateSheet";
import { MachineDetailView } from "./MachineDetail";
import { MachineList } from "./MachineList";
import { MigrationBanner, PlanNotice } from "./Notices";
import type { CloudStore } from "./store";
import { Storefront } from "./Storefront";
import { errorText, L } from "./strings";

export function CloudPage({ store, strings }: { store: CloudStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  // A lost link shows nothing until it lasts past the grace (a launch, a daemon restart: the store
  // reads again on its own); then the disconnected state with Retry.
  const down = snap.connection === "disconnected";
  const failed = snap.connection === "failed";
  const downLasting = useLasting(down);
  const signedIn = !!snap.auth?.signedIn && snap.connection === "connected";
  const storefront = signedIn && (snap.view === "get" || (!snap.loading && snap.rows.length === 0));
  // The header switches between the list and the storefront once the team has a machine.
  const viewSwitch =
    signedIn && snap.rows.length > 0 ? (
      <button
        type="button"
        className="cloud-button cloud-view-switch"
        onClick={() => store.setView(snap.view === "get" ? "machines" : "get")}
      >
        {t(snap.view === "get" ? L.storeYourMachines : L.storeBrowse)}
      </button>
    ) : null;
  const body = () => {
    if (down && !downLasting) return null;
    if (failed)
      return (
        <div className="cloud-message cloud-failed" role="alert">
          <p>{t(L.actionFailed)}</p>
          {snap.error && <p className="cloud-error-detail">{errorText(snap.error, snap.errorCode, t)}</p>}
          {store.canRetry && (
            <button type="button" className="cloud-button cloud-retry-button" onClick={() => void store.retry()}>
              {t(L.retry)}
            </button>
          )}
        </div>
      );
    if (down)
      return (
        <div className="cloud-message cloud-disconnected">
          <p>{t(L.disconnected)}</p>
          {store.canRetry && (
            <button type="button" className="cloud-button cloud-retry-button" onClick={() => void store.retry()}>
              {t(L.retry)}
            </button>
          )}
        </div>
      );
    if (!snap.auth || (snap.loading && snap.rows.length === 0))
      return <div className="cloud-message cloud-loading">{t(L.loading)}</div>;
    // Signed out, with no machines yet, or at `#/get`: the storefront (Storefront.tsx).
    if (!snap.auth.signedIn || storefront)
      return (
        <>
          {snap.refusal && (
            <PlanNotice refusal={snap.refusal} strings={strings} onDismiss={() => store.dismissError()} />
          )}
          {snap.blocked === "no_snapshot_configured" && (
            <div className="cloud-error cloud-blocked" role="alert">
              <span className="cloud-error-text">{t(L.noSnapshotConfigured)}</span>
              <button type="button" className="cloud-link-button" onClick={() => store.dismissError()}>
                {t(L.dismissError)}
              </button>
            </div>
          )}
          <Storefront store={store} state={snap} strings={strings} />
        </>
      );
    const selected = snap.rows.find((row) => row.id === snap.selection);
    return (
      <>
        <MigrationBanner store={store} state={snap} strings={strings} />
        {snap.refusal && <PlanNotice refusal={snap.refusal} strings={strings} onDismiss={() => store.dismissError()} />}
        {snap.blocked === "no_snapshot_configured" && (
          <div className="cloud-error cloud-blocked" role="alert">
            <span className="cloud-error-text">{t(L.noSnapshotConfigured)}</span>
            <button type="button" className="cloud-link-button" onClick={() => store.dismissError()}>
              {t(L.dismissError)}
            </button>
          </div>
        )}
        <div className={`cloud-body layout-${snap.layout}`}>
          <section className="cloud-machines" aria-label={t(L.machines)}>
            <div className="cloud-section-header">
              <h2 className="cloud-section-title">{t(L.machines)}</h2>
              <button type="button" className="cloud-button cloud-create-button" onClick={() => store.openCreate()}>
                {t(L.create)}
              </button>
            </div>
            <MachineList
              rows={snap.rows}
              layout={snap.layout}
              selection={snap.selection}
              strings={strings}
              onSelect={(id) => void store.select(id)}
              onOpen={(id) => void store.connect(id)}
              onPause={(id) => void store.pause(id)}
              onResume={(id) => void store.resume(id)}
            />
          </section>
          {selected?.machine && snap.detail?.machine === selected.id ? (
            <MachineDetailView
              key={selected.id}
              store={store}
              row={selected}
              detail={snap.detail}
              plan={snap.plan}
              migration={snap.migration}
              unavailable={snap.unavailable}
              transfers={snap.transfers}
              strings={strings}
            />
          ) : (
            <div className="cloud-message cloud-detail-placeholder">{t(L.selectMachine)}</div>
          )}
          <AccountPanel store={store} state={snap} strings={strings} />
        </div>
      </>
    );
  };
  return (
    <div className="cloud-page">
      <header className="cloud-header">
        <h1 className="cloud-title">{t(L.title)}</h1>
        {viewSwitch}
      </header>
      {snap.error && snap.connection !== "disconnected" && snap.connection !== "failed" && (
        <div className="cloud-error" role="alert">
          <span className="cloud-error-text">
            <span>{t(L.actionFailed)}</span>
            <span className="cloud-error-detail">{errorText(snap.error, snap.errorCode, t)}</span>
          </span>
          <button type="button" className="cloud-link-button" onClick={() => store.dismissError()}>
            {t(L.dismissError)}
          </button>
        </div>
      )}
      {body()}
      {snap.create && <CreateSheet store={store} state={snap} draft={snap.create} strings={strings} />}
    </div>
  );
}

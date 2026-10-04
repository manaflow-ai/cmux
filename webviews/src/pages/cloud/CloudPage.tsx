// The Cloud page (plans/cmux-next/cloud-app.md L7, cloud-parity.md "cmux-next UI mapping"). State
// lives in `CloudStore`; this file only renders it and turns plain keys and clicks into intents.
// Cmd and Ctrl chords never reach a page handler (`plain`): the app's key dispatcher owns them.
import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { AccountPanel } from "./AccountPanel";
import { CreateSheet } from "./CreateSheet";
import { MachineDetailView } from "./MachineDetail";
import { MachineList } from "./MachineList";
import type { CloudStore } from "./store";
import { L } from "./strings";

export function CloudPage({ store, strings }: { store: CloudStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  const body = () => {
    if (snap.connection === "disconnected")
      return <div className="cloud-message cloud-disconnected">{t(L.disconnected)}</div>;
    if (!snap.auth || (snap.loading && snap.rows.length === 0))
      return <div className="cloud-message cloud-loading">{t(L.loading)}</div>;
    if (!snap.auth.signed_in)
      return (
        <div className="cloud-message cloud-signed-out">
          <h2 className="cloud-message-title">{t(L.signedOutTitle)}</h2>
          <p>{t(L.signedOutBody)}</p>
          <button
            type="button"
            className="cloud-button primary cloud-signin-button"
            onClick={() => void store.signIn()}
          >
            {t(L.signIn)}
          </button>
        </div>
      );
    const selected = snap.rows.find((row) => row.id === snap.selection);
    return (
      <div className={`cloud-body layout-${snap.layout}`}>
        <section className="cloud-machines" aria-label={t(L.machines)}>
          <div className="cloud-section-header">
            <h2 className="cloud-section-title">{t(L.machines)}</h2>
            <button type="button" className="cloud-button cloud-create-button" onClick={() => store.openCreate()}>
              {t(L.create)}
            </button>
          </div>
          {snap.rows.length === 0 ? (
            <div className="cloud-message cloud-empty">
              <h3 className="cloud-message-title">{t(L.empty)}</h3>
              <p>{t(L.emptyBody)}</p>
            </div>
          ) : (
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
          )}
        </section>
        {selected?.machine && snap.detail?.machine === selected.id ? (
          <MachineDetailView store={store} row={selected} detail={snap.detail} plan={snap.plan} strings={strings} />
        ) : (
          <div className="cloud-message cloud-detail-placeholder">{t(L.selectMachine)}</div>
        )}
        <AccountPanel store={store} state={snap} strings={strings} />
      </div>
    );
  };
  return (
    <div className="cloud-page">
      <header className="cloud-header">
        <h1 className="cloud-title">{t(L.title)}</h1>
      </header>
      {snap.error && snap.connection !== "disconnected" && (
        <div className="cloud-error" role="alert">
          <span>{snap.error}</span>
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

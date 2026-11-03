import { useState } from "react";
import { useSettingsState, useStore } from "../context";

/** The host owns GitHub App authentication; this card never receives a credential. */
export function GitHubAccountsCard() {
  const github = useSettingsState().accounts?.github;
  const store = useStore();
  const [confirming, setConfirming] = useState<string | null>(null);
  if (!github) return null;
  return (
    <section className="group" data-card="github-connection" aria-busy={github.busy}>
      <h3 className="group-title">{github.title}</h3>
      <div className="rows">
        <div className="row accounts-row">
          <div className="row-label">
            <p className="row-help">{github.detail}</p>
          </div>
          <div className="accounts-body">
            <div className="accounts-buttons">
              <button
                className="button"
                data-github-action="connect"
                disabled={!github.canConnect}
                onClick={() => void store.runAccounts({ action: "githubConnect" })}
              >
                {github.connect}
              </button>
              <button
                className="button"
                disabled={github.busy}
                onClick={() => void store.runAccounts({ action: "githubRefresh" })}
              >
                {github.refresh}
              </button>
            </div>
          </div>
        </div>
        {github.connections.map((connection) => (
          <div className="row accounts-row" key={connection.id} data-github-connection={connection.id}>
            <div className="row-label">
              <span className="row-title">{connection.account}</span>
              <p className="row-help">{connection.status}</p>
              <p className="row-help">{connection.permissions.join(" · ")}</p>
              {confirming === connection.id && <output className="row-help">{github.confirm}</output>}
            </div>
            <div className="accounts-body">
              <div className="accounts-buttons">
                {confirming === connection.id ? (
                  <>
                    <button
                      className="button"
                      disabled={github.busy}
                      onClick={() => {
                        setConfirming(null);
                        void store.runAccounts({
                          action: "githubDisconnect",
                          account: connection.id,
                        });
                      }}
                    >
                      {github.disconnect}
                    </button>
                    <button className="button" onClick={() => setConfirming(null)}>
                      {github.cancel}
                    </button>
                  </>
                ) : (
                  <button
                    className="button danger"
                    data-github-action="disconnect"
                    disabled={github.busy || !connection.canDisconnect}
                    onClick={() => setConfirming(connection.id)}
                  >
                    {github.disconnect}
                  </button>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

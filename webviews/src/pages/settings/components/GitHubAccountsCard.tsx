import { useState } from "react";
import { Button } from "../../../ui/Button";
import { SignInButton } from "../../../ui/SignInButton";
import { useSettingsState, useStore } from "../context";
import { LOAD_FADE_CLASS, useLoadFade } from "../../../agent-session/shared/loadFade";

/** The host owns GitHub App authentication; this card never receives a credential. */
export function GitHubAccountsCard() {
  const github = useSettingsState().accounts?.github;
  const store = useStore();
  const [confirming, setConfirming] = useState<string | null>(null);
  // The card arrives with the host's lists: after a blank first paint it fades in (shared/loadFade.ts).
  const fade = useLoadFade(Boolean(github));
  if (!github) return null;
  return (
    <section
      className={fade ? `group ${LOAD_FADE_CLASS}` : "group"}
      data-card="github-connection"
      aria-busy={github.busy}
    >
      <h3 className="group-title">{github.title}</h3>
      <div className="rows">
        <div className="row accounts-row">
          <div className="row-label">
            <p className="row-help">{github.detail}</p>
          </div>
          <div className="accounts-body">
            <div className="accounts-buttons">
              {github.signIn ? (
                <SignInButton label={github.signIn} onSignIn={() => void store.runAccounts({ action: "signIn" })} />
              ) : (
                <Button
                  className="button"
                  data-github-action="connect"
                  disabled={!github.canConnect}
                  onClick={() => void store.runAccounts({ action: "githubConnect" })}
                >
                  {github.connect}
                </Button>
              )}
              <Button
                className="button"
                disabled={github.busy}
                onClick={() => void store.runAccounts({ action: "githubRefresh" })}
              >
                {github.refresh}
              </Button>
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
                    <Button
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
                    </Button>
                    <Button className="button" onClick={() => setConfirming(null)}>
                      {github.cancel}
                    </Button>
                  </>
                ) : (
                  <Button
                    danger
                    className="button danger"
                    data-github-action="disconnect"
                    disabled={github.busy || !connection.canDisconnect}
                    onClick={() => setConfirming(connection.id)}
                  >
                    {github.disconnect}
                  </Button>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

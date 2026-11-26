import { useState } from "react";
import { Button } from "../../../ui/Button";
import { SignInButton } from "../../../ui/SignInButton";
import { DeviceSignInCard } from "../../shared/signIn/DeviceSignInCard";
import { parseAccountRow, type AccountRowWire } from "../../shared/signIn/accountSignIn";
import type { ActiveSignIn } from "../../shared/signIn/AccountSwitcher";
import { useSettingsState, useStore } from "../context";
import { LOAD_FADE_CLASS, useLoadFade } from "../../../agent-session/shared/loadFade";
import { terminalSignIn, type SettingsSignIn } from "./useSettingsSignIn";
import { t } from "../strings";

export function shouldShowGitHubSignIn(running: ActiveSignIn | null, rows: readonly AccountRowWire[]): boolean {
  return running?.family === "github" && (running.account === null || !rows.some((row) => row.id === running.account));
}

/** The host owns GitHub App authentication; this card never receives a credential. */
export function GitHubAccountsCard({ signIn }: { signIn: SettingsSignIn }) {
  const accounts = useSettingsState().accounts;
  const github = accounts?.github;
  const store = useStore();
  const [confirming, setConfirming] = useState<string | null>(null);
  // The card arrives with the host's lists: after a blank first paint it fades in (shared/loadFade.ts).
  const fade = useLoadFade(Boolean(github));
  if (!github) return null;
  const cliLabel = github.cliSignIn ?? t("github.cliSignIn");
  const cliDetail = github.cliSignInDetail ?? t("github.cliSignInDetail");
  const signInRows = accounts?.signInAccounts?.flatMap((raw) => parseAccountRow(raw) ?? []) ?? [];
  const running = signIn.running;
  const showSignIn = shouldShowGitHubSignIn(running, signInRows);
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
                <SignInButton
                  label={github.signIn}
                  backend={github.signInBackend}
                  onSignIn={() => void store.runAccounts({ action: "signIn" })}
                />
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
            <p className="row-help">{cliDetail}</p>
            <div className="accounts-buttons">
              <Button
                className="button"
                variant="ghost"
                data-github-action="cli-sign-in"
                disabled={Boolean(signIn.running)}
                onClick={() => {
                  if (!signIn.inPlace) {
                    void store.runHarnesses(terminalSignIn("github", null));
                    return;
                  }
                  signIn.begin("github", null, () => void store.runHarnesses(terminalSignIn("github", null)));
                }}
              >
                {cliLabel}
              </Button>
            </div>
            {showSignIn && running && (
              <div className="accounts-body">
                <DeviceSignInCard family="github" view={running.view} look="inline" {...signIn.card} />
              </div>
            )}
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
                  <>
                    {github.reconfigure && connection.canReconfigure && (
                      // The installation's own page on GitHub: which repositories, and the account or org access.
                      <Button
                        className="button"
                        data-github-action="reconfigure"
                        disabled={github.busy}
                        onClick={() => void store.runAccounts({ action: "githubReconfigure", account: connection.id })}
                      >
                        {github.reconfigure}
                      </Button>
                    )}
                    <Button
                      danger
                      className="button danger"
                      data-github-action="disconnect"
                      disabled={github.busy || !connection.canDisconnect}
                      onClick={() => setConfirming(connection.id)}
                    >
                      {github.disconnect}
                    </Button>
                  </>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

// Onboarding's provider readiness (logins done right): one row per provider (GitHub, ChatGPT,
// Claude) with where it stands and one action. Not installed: Install. Installing: nothing to do but
// wait, so no button. Sign-in required: Sign in, which opens the device card in the row. Signing in:
// the card itself (the code and Copy). Ready: the account, and Add account for another personal one.
// Failed: why, and Try again. Pure props: the caller runs each action; nothing here talks to a host.
import { Button } from "../../../ui/Button";
import { StatusGlyph } from "../../../ui/StatusGlyph";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import { FAMILY_BRAND, type AccountFamily, type SignInView } from "./accountSignIn";
import { DeviceSignInCard, ProviderMark, type DeviceSignInCardProps } from "./DeviceSignInCard";
import { useSignInStrings } from "./strings";

export type ReadinessState = "notInstalled" | "installing" | "signInRequired" | "signingIn" | "ready" | "failed";

export type ReadinessRow = {
  family: AccountFamily;
  state: ReadinessState;
  /** Ready: the signed-in account. */
  account?: string;
  /** Signing in: the card's view. */
  view?: SignInView;
  /** Failed: the reason, already localized by whoever failed. */
  reason?: string;
};

/** The one action a readiness row offers (`null`: installing, which only waits). */
export type ReadinessAction = "install" | "signIn" | "addAccount" | "tryAgain";

export function readinessAction(state: ReadinessState): ReadinessAction | null {
  switch (state) {
    case "notInstalled":
      return "install";
    case "installing":
      return null;
    case "signInRequired":
      return "signIn";
    case "signingIn":
      return null;
    case "ready":
      return "addAccount";
    case "failed":
      return "tryAgain";
  }
}

const ACTION_KEY: Record<ReadinessAction, string> = {
  install: "signIn.install",
  signIn: "signIn.account.signIn",
  addAccount: "signIn.account.add",
  tryAgain: "signIn.tryAgain",
};

export type ProviderReadinessProps = {
  rows: readonly ReadinessRow[];
  onAction?(family: AccountFamily, action: ReadinessAction): void;
  /** The device card's gestures for the row that signs in. */
  card?: Omit<DeviceSignInCardProps, "family" | "view" | "look">;
};

export function ProviderReadiness({ rows, onAction, card }: ProviderReadinessProps) {
  const strings = useSignInStrings();
  const status = (row: ReadinessRow): string => {
    switch (row.state) {
      case "notInstalled":
        return strings.t("signIn.ready.notInstalled");
      case "installing":
        return strings.t("signIn.ready.installing");
      case "signInRequired":
        return strings.t("signIn.ready.signInRequired");
      case "signingIn":
        return strings.t("signIn.ready.signingIn");
      case "ready":
        return row.account ? strings.format("signIn.signedIn", row.account) : strings.t("signIn.ready.ready");
      case "failed":
        return strings.format("signIn.ready.failed", row.reason ?? strings.t("signIn.failed.other"));
    }
  };
  return (
    <ul className="signin-ready">
      {rows.map((row) => {
        const action = readinessAction(row.state);
        return (
          <li className="signin-ready-row" key={row.family} data-ready-family={row.family} data-ready-state={row.state}>
            <div className="signin-ready-main">
              <ProviderMark family={row.family} size={20} />
              <span className="signin-ready-name">{FAMILY_BRAND[row.family]}</span>
              <span className="signin-ready-status" data-tone={row.state}>
                {row.state === "installing" || row.state === "signingIn" ? (
                  <Spinner size={12} loading />
                ) : row.state === "ready" ? (
                  <StatusGlyph name="done" size={12} />
                ) : row.state === "failed" ? (
                  <StatusGlyph name="error" size={12} />
                ) : null}
                <span>{status(row)}</span>
              </span>
              <span className="signin-ready-slot">
                {action && (
                  <Button
                    size="sm"
                    variant={action === "addAccount" ? "ghost" : "solid"}
                    data-ready-action={action}
                    onClick={() => onAction?.(row.family, action)}
                  >
                    {strings.t(ACTION_KEY[action])}
                  </Button>
                )}
              </span>
            </div>
            {row.state === "signingIn" && row.view && (
              <DeviceSignInCard family={row.family} view={row.view} look="inline" {...card} />
            )}
          </li>
        );
      })}
    </ul>
  );
}

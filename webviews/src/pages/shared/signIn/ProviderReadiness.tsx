// Onboarding's provider readiness (logins done right): where each provider (GitHub, ChatGPT, Claude)
// stands and its one action. Not installed: Install. Installing: nothing to do but wait, so no
// button. Sign-in required: Sign In, which opens the device card in the row. Signing in: the card
// itself (the code and Copy). Ready: the account, and Add Account for another personal one. Failed:
// why, and Try Again. The agents step (onboarding/AgentsStep.tsx) draws these in its own agent list:
// Claude Code and Codex take their provider's state in place, and GitHub is one more row of that list.
import type { Strings } from "../i18n";
import type { AccountFamily, SignInView } from "./accountSignIn";
import type { DeviceSignInCardProps } from "./DeviceSignInCard";

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

/** The one action a readiness row offers (`null`: installing or signing in, which only wait). */
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

export const READINESS_ACTION_KEY: Record<ReadinessAction, string> = {
  install: "signIn.install",
  signIn: "signIn.account.signIn",
  addAccount: "signIn.account.add",
  tryAgain: "signIn.tryAgain",
};

/** The row's one status line. */
export function readinessStatus(strings: Strings, row: ReadinessRow): string {
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
}

/** The provider an onboarding agent row signs in to (Claude Code: Claude; Codex: ChatGPT), if any. */
export function agentFamily(agentId: string): AccountFamily | null {
  return agentId === "claude" || agentId === "codex" ? agentId : null;
}

/** What the host gives the agents step to sign providers in place. */
export type ProviderReadinessProps = {
  rows: readonly ReadinessRow[];
  onAction?(family: AccountFamily, action: ReadinessAction): void;
  /** Whether Install can run for a provider (an agent row installs it); absent: always. */
  canInstall?(family: AccountFamily): boolean;
  /** The device card's gestures for the row that signs in. */
  card?: Omit<DeviceSignInCardProps, "family" | "view" | "look">;
};

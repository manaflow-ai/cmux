// The agents step's in-place sign-in (logins done right): the rows AgentsStep draws, built from the
// host's state. The daemon decides where each provider stands (`signInReadiness`: not installed,
// sign-in required, ready); the page never re-derives it and only lays its own moments over it:
// installing from the agents rows, and a sign-in in progress (starting, the code, expired, failed,
// signed in) from the shared controller (shared/signIn/useAccountSignIn.ts) that Settings runs too,
// here over `cmux.onboarding.accounts.run`. A host without `signInReadiness` gets nothing, and the
// list is as it was.
import { useMemo } from "react";
import type { Strings } from "../shared/i18n";
import type { AccountFamily, AccountRunParams, SignInView } from "../shared/signIn/accountSignIn";
import type { ActiveSignIn } from "../shared/signIn/AccountSwitcher";
import { agentFamily, type ProviderReadinessProps, type ReadinessRow } from "../shared/signIn/ProviderReadiness";
import { useSignInStrings } from "../shared/signIn/strings";
import { useAccountSignIn, type AccountSignInTransport } from "../shared/signIn/useAccountSignIn";
import { OPS, type OnboardingState } from "./ops";
import type { OnboardingStore } from "./store";

/** Why a sign-in ended without an account, in the row's one line. */
function failureReason(strings: Strings, view: SignInView): string {
  if (view.state === "expired") return strings.t("signIn.expired");
  if (view.state === "failed" && view.reason === "cancelled") return strings.t("signIn.failed.cancelled");
  if (view.state === "failed" && view.reason === "shared_machine") return strings.t("signIn.failed.sharedMachine");
  return strings.t("signIn.failed.other");
}

/** The agent row that installs or signs in to a provider (Claude Code: Claude, Codex: ChatGPT). */
function agentFor(state: OnboardingState, family: AccountFamily) {
  return state.agents?.rows.find((row) => agentFamily(row.id) === family);
}

/** The rows, or null when the host does not send the providers' readiness. */
export function readinessRows(
  state: OnboardingState | null,
  running: ActiveSignIn | null,
  strings: Strings,
): ReadinessRow[] | null {
  const providers = state?.signInReadiness?.providers;
  if (!state || !Array.isArray(providers)) return null;
  const accounts = state.signInAccounts ?? [];
  return providers.map((provider): ReadinessRow => {
    const family = provider.family;
    const shown =
      provider.label ?? accounts.find((row) => row.id === provider.account)?.name ?? provider.account ?? undefined;
    if (running?.family === family) {
      const view = running.view;
      switch (view.state) {
        case "starting":
        case "waiting":
          return { family, state: "signingIn", view };
        case "signedIn":
          return { family, state: "ready", account: view.account ?? shown };
        case "notInstalled":
          return { family, state: "notInstalled" };
        case "expired":
        case "failed":
          // Signed in some other way meanwhile: the daemon's ready wins over an old failure.
          if (provider.state === "ready") break;
          return { family, state: "failed", reason: failureReason(strings, view) };
      }
    }
    if (agentFor(state, family)?.install?.state === "installing") return { family, state: "installing" };
    if (provider.state === "ready") return { family, state: "ready", account: shown };
    return { family, state: provider.state };
  });
}

/** The agents step's readiness and its gestures; undefined on a host without it. */
export function useOnboardingReadiness(
  store: OnboardingStore,
  state: OnboardingState | null,
): ProviderReadinessProps | undefined {
  const strings = useSignInStrings();
  const transport = useMemo<AccountSignInTransport>(
    () => ({
      run: (params: AccountRunParams) => store.runAccountSignIn(params),
      // A host that answers a start without a sign-in: the agent's own Sign In (its terminal tab).
      fallback: (family) => {
        const now = store.getSnapshot();
        const agent = now ? agentFor(now, family) : undefined;
        if (agent) store.call(OPS.signIn, { id: agent.id });
      },
    }),
    [store],
  );
  const signIn = useAccountSignIn(transport);
  const rows = readinessRows(state, signIn.running, strings);
  if (!rows || !state) return undefined;
  const accountFor = (family: AccountFamily) => {
    const account = state.signInReadiness?.providers.find((provider) => provider.family === family)?.account;
    return account && (state.signInAccounts ?? []).some((row) => row.id === account) ? account : null;
  };
  return {
    rows,
    onAction: (family, action) => {
      switch (action) {
        case "install": {
          const agent = agentFor(state, family);
          if (agent) store.call(OPS.install, { id: agent.id });
          return;
        }
        case "signIn":
          return signIn.start(family, accountFor(family));
        case "addAccount":
          return signIn.start(family, null);
        case "tryAgain":
          return signIn.running?.family === family
            ? signIn.start(family, signIn.running.account)
            : signIn.start(family, accountFor(family));
      }
    },
    canInstall: (family) => agentFor(state, family) != null,
    card: signIn.card,
  };
}

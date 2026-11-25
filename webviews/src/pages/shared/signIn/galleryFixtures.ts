// l10n-allow-file: gallery fixtures (sample account names and codes), not shipped UI.
// The sign-in card's states and the account list's cases, for the gallery entries beside this file
// and the tests. Public-safe: example.com names and made-up codes.
import type { AccountFamily, AccountRowWire, SignInView } from "./accountSignIn";

/** Every state the card draws, by the name the gallery shows. */
export const SIGN_IN_STATES = {
  starting: { state: "starting" },
  code: {
    state: "waiting",
    way: { kind: "code", code: "K7QX-29PF" },
    copied: true,
    url: "https://auth.openai.com/codex/device",
  },
  "code-not-copied": {
    state: "waiting",
    way: { kind: "code", code: "WDJB-MJHT" },
    copied: false,
    url: "https://github.com/login/device",
  },
  approve: { state: "waiting", way: { kind: "approve" }, copied: false, url: "https://claude.ai/oauth/authorize" },
  paste: { state: "waiting", way: { kind: "paste" }, copied: false, url: "https://claude.ai/oauth/authorize" },
  "signed-in": { state: "signedIn", account: "you@example.com" },
  expired: { state: "expired" },
  cancelled: { state: "failed", reason: "cancelled" },
  "shared-machine": { state: "failed", reason: "shared_machine" },
  failed: { state: "failed", reason: "other" },
  "not-installed": { state: "notInstalled" },
} satisfies Record<string, SignInView>;

export type SignInStateName = keyof typeof SIGN_IN_STATES;

/** The provider each state is shown with (a code is ChatGPT's or GitHub's, a pasted code Claude's). */
export const SIGN_IN_STATE_FAMILY: Record<SignInStateName, AccountFamily> = {
  starting: "github",
  code: "codex",
  "code-not-copied": "github",
  approve: "claude",
  paste: "claude",
  "signed-in": "codex",
  expired: "github",
  cancelled: "codex",
  "shared-machine": "claude",
  failed: "github",
  "not-installed": "claude",
};

const row = (id: string, family: AccountFamily, name: string, extra: Partial<AccountRowWire> = {}): AccountRowWire => ({
  id,
  family,
  name,
  signedIn: true,
  default: false,
  builtin: false,
  ...extra,
});

/** The account list's cases. */
export const ACCOUNT_LISTS = {
  none: [],
  oneEach: [
    row("github-1", "github", "octocat", { default: true }),
    row("codex-1", "codex", "you@example.com", { plan: "Plus", default: true, builtin: true }),
    row("claude-1", "claude", "you@example.com", { plan: "Max", default: true, builtin: true }),
  ],
  twoEach: [
    row("github-1", "github", "octocat", { default: true }),
    row("github-2", "github", "octo-work", { email: "octo@example.com" }),
    row("codex-1", "codex", "you@example.com", { plan: "Plus", default: true, builtin: true }),
    row("codex-2", "codex", "you.work@example.com", { plan: "Team" }),
    row("claude-1", "claude", "you@example.com", { plan: "Max", default: true, builtin: true }),
    row("claude-2", "claude", "lab@example.com", { plan: "Pro" }),
  ],
  signedOut: [
    row("github-1", "github", "octocat", { default: true }),
    row("github-2", "github", "octo-work", { signedIn: false }),
    row("codex-1", "codex", "you@example.com", { plan: "Plus", default: true, builtin: true, signedIn: false }),
    row("claude-1", "claude", "you@example.com", { plan: "Max", default: true, builtin: true }),
  ],
} satisfies Record<string, AccountRowWire[]>;

export type AccountListName = keyof typeof ACCOUNT_LISTS;

/** One provider as the daemon reports it (onboarding's `signInReadiness`). */
export type ReadinessProviderFixture = {
  family: AccountFamily;
  state: "notInstalled" | "signInRequired" | "ready";
  account?: string;
  label?: string;
};

/** Onboarding's provider readiness cases as a host sends them: the daemon's readiness and the
 * accounts (`signInAccounts`), plus what the gallery does on top: an agent installing (the agents
 * state) and a sign-in it starts through the mock's `cmux.onboarding.accounts.run` (held on its
 * code, or refused with a reason). */
export type ReadinessFixtureCase = {
  providers: ReadinessProviderFixture[];
  accounts: AccountRowWire[];
  installing?: AccountFamily[];
  signIn?: { family: AccountFamily; refusal?: string };
};

const github = row("github-1", "github", "octocat", { default: true });

export const READINESS = {
  fresh: {
    providers: [
      { family: "github", state: "signInRequired" },
      { family: "codex", state: "notInstalled" },
      { family: "claude", state: "signInRequired" },
    ],
    accounts: [],
  },
  mixed: {
    providers: [
      { family: "github", state: "ready", account: "github-1" },
      { family: "codex", state: "notInstalled" },
      { family: "claude", state: "signInRequired" },
    ],
    accounts: [github],
    installing: ["codex"],
    signIn: { family: "claude", refusal: "cancelled" },
  },
  signingIn: {
    providers: [
      { family: "github", state: "ready", account: "github-1" },
      { family: "codex", state: "signInRequired" },
      { family: "claude", state: "signInRequired" },
    ],
    accounts: [github],
    signIn: { family: "codex" },
  },
  ready: {
    providers: [
      { family: "github", state: "ready", account: "github-1" },
      { family: "codex", state: "ready", account: "codex-1" },
      { family: "claude", state: "ready", account: "claude-1" },
    ],
    accounts: ACCOUNT_LISTS.oneEach,
  },
} satisfies Record<string, ReadinessFixtureCase>;

export type ReadinessFixture = keyof typeof READINESS;

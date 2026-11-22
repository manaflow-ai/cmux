// l10n-allow-file: gallery fixtures (sample account names and codes), not shipped UI.
// The sign-in card's states and the account list's cases, for the gallery entries beside this file
// and the tests. Public-safe: example.com names and made-up codes.
import type { AccountFamily, AccountRowWire, SignInView } from "./accountSignIn";
import type { ReadinessRow } from "./ProviderReadiness";

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
  "signed-in": { state: "signedIn", account: "ada@example.com" },
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
    row("codex-1", "codex", "ada@example.com", { plan: "Plus", default: true, builtin: true }),
    row("claude-1", "claude", "ada@example.com", { plan: "Max", default: true, builtin: true }),
  ],
  twoEach: [
    row("github-1", "github", "octocat", { default: true }),
    row("github-2", "github", "octo-work", { email: "octo@example.com" }),
    row("codex-1", "codex", "ada@example.com", { plan: "Plus", default: true, builtin: true }),
    row("codex-2", "codex", "ada.work@example.com", { plan: "Team" }),
    row("claude-1", "claude", "ada@example.com", { plan: "Max", default: true, builtin: true }),
    row("claude-2", "claude", "lab@example.com", { plan: "Pro" }),
  ],
  signedOut: [
    row("github-1", "github", "octocat", { default: true }),
    row("github-2", "github", "octo-work", { signedIn: false }),
    row("codex-1", "codex", "ada@example.com", { plan: "Plus", default: true, builtin: true, signedIn: false }),
    row("claude-1", "claude", "ada@example.com", { plan: "Max", default: true, builtin: true }),
  ],
} satisfies Record<string, AccountRowWire[]>;

export type AccountListName = keyof typeof ACCOUNT_LISTS;

/** Onboarding's provider readiness cases (ProviderReadiness.tsx), one row per provider. */
export const READINESS = {
  fresh: [
    { family: "github", state: "signInRequired" },
    { family: "codex", state: "notInstalled" },
    { family: "claude", state: "signInRequired" },
  ],
  mixed: [
    { family: "github", state: "ready", account: "octocat" },
    { family: "codex", state: "installing" },
    { family: "claude", state: "failed", reason: "the page was closed" },
  ],
  signingIn: [
    { family: "github", state: "ready", account: "octocat" },
    { family: "codex", state: "signingIn", view: SIGN_IN_STATES.code },
    { family: "claude", state: "signInRequired" },
  ],
  ready: [
    { family: "github", state: "ready", account: "octocat" },
    { family: "codex", state: "ready", account: "ada@example.com" },
    { family: "claude", state: "ready", account: "ada@example.com" },
  ],
} satisfies Record<string, ReadinessRow[]>;

export type ReadinessFixture = keyof typeof READINESS;

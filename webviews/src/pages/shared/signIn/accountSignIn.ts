// The one place that knows the daemon's account sign-in wire (acpmux `_acpmux/account/sign_in`,
// `server/account_sign_in.rs`) and turns it into what the sign-in card draws. Leo, 2026-11-22: "we likewise
// want gh auth or device stuff to be much more convienient ui/ux wise ... this is simply logins,
// done righr." When a wire name or field changes, change it here and nowhere else.
//
// The flow: one click on Add account or Sign in starts `account.sign_in`; the host opens the
// provider's page in the app's own browser pane beside the window and the card shows the one-time
// code (already on the clipboard). `account.sign_in.finish` waits for the approval (Codex, GitHub,
// Claude's approve-in-page) or takes the code Claude's page shows (`needsCode`). The card then
// turns into the signed-in account. The code lives only in the card's own state: never in a store,
// a log or a data attribute.
import { signInURL, autoSignIn } from "../../../agent-session/acpmux/cloudAgentLogin";

/** The providers an account can sign in to. */
export type AccountFamily = "codex" | "claude" | "github";
export const ACCOUNT_FAMILIES: readonly AccountFamily[] = ["github", "codex", "claude"];

/** The daemon's methods (the host relays them). */
export const ACCOUNT_METHODS = {
  start: "account.sign_in",
  finish: "account.sign_in.finish",
  cancel: "account.sign_in.cancel",
  switch: "account.switch",
  remove: "account.remove",
  /** Not in the first wire brief (it named Use, Sign out and Remove but no sign-out method): the
   * name the page sends until the daemon names its own. */
  signOut: "account.sign_out",
} as const;

/** The same gestures as Settings > Accounts run actions (`cmux.settings.accounts.run`), which the
 * host forwards to ``ACCOUNT_METHODS``. A host that does not know them answers without a sign-in
 * and the page keeps its terminal path. */
export const ACCOUNT_ACTIONS = {
  start: "signInStart",
  finish: "signInFinish",
  cancel: "signInCancel",
  switch: "accountSwitch",
  remove: "accountRemove",
  signOut: "accountSignOut",
} as const;

/** `account.sign_in`'s params. */
export type SignInStartParams = { account?: string; family?: AccountFamily; name?: string };

/** `account.sign_in`'s answer. */
export type SignInStartWire = {
  account: string;
  loginId: string;
  url: string;
  autoUrl?: string;
  callbackPort?: number;
  userCode?: string;
  needsCode: boolean;
  expiresAtMs: number;
  added: boolean;
};

/** `account.sign_in.finish`'s answer. */
export type SignInFinishWire = { signedIn: boolean; account: string };

/** One sign-in gesture as a page sends it to its host (`cmux.settings.accounts.run`,
 * `cmux.onboarding.accounts.run`): an ACCOUNT_ACTIONS action and its params. */
export type AccountRunParams = {
  action: string;
  provider?: string;
  account?: string;
  loginId?: string;
  code?: string;
  family?: AccountFamily;
  /** A new account's typed name (a start without `account`; the daemon keeps its first 128 characters). */
  name?: string;
};

/** The host's answer to a sign-in gesture: `signIn` for a start, `finished` for a finish, `reason`
 * for a refusal (SignInFailure). `terminal`: the host's daemon has no in-place sign-in, and the host
 * already ran the start's terminal sign-in inside the same call (while the click still counts as
 * the person's), so the page draws nothing and runs no fallback of its own. */
export type AccountRunReply = {
  error?: string;
  signIn?: SignInStartWire;
  terminal?: boolean;
  finished?: SignInFinishWire;
  reason?: string;
};

/** A gesture's outcome: the answer, or the refusal the call rejected with. */
export type AccountRunResult = { ok: true; value: AccountRunReply } | { ok: false; error: unknown };

/** One row of the account list. */
export type AccountRowWire = {
  id: string;
  family: AccountFamily;
  name: string;
  email?: string;
  plan?: string;
  signedIn: boolean;
  default: boolean;
  builtin: boolean;
};

/** Why a step failed (the daemon's `reason`; anything else is `other`). */
export type SignInFailure = "not_installed" | "expired" | "cancelled" | "shared_machine" | "other";

/** A started sign-in, checked: only a provider's own https page, and Claude's automatic page only
 * when its redirect names the port the daemon gave. */
export type SignInStarted = {
  account: string;
  loginId: string;
  url: string;
  /** How the person finishes: type or paste `code` there, approve in the page, or paste the page's code here. */
  way: { kind: "code"; code: string } | { kind: "approve" } | { kind: "paste" };
  expiresAtMs: number;
  added: boolean;
};

const GITHUB_HOSTS = new Set(["github.com"]);

/** `raw` as a page the card may name: a Claude, OpenAI or GitHub sign-in page over https. */
export function accountSignInURL(raw: unknown): string | undefined {
  const known = signInURL(raw);
  if (known) return known;
  if (typeof raw !== "string") return undefined;
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || url.username || url.password || url.port) return undefined;
    return GITHUB_HOSTS.has(url.hostname.toLowerCase()) ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

/** `account.sign_in`'s answer as the card's start; undefined when it is not one (an older host). */
export function parseSignInStart(reply: unknown): SignInStarted | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const value = reply as Partial<Record<keyof SignInStartWire, unknown>>;
  if (typeof value.loginId !== "string" || !value.loginId) return undefined;
  if (typeof value.account !== "string" || !value.account) return undefined;
  const url = accountSignInURL(value.url);
  if (!url) return undefined;
  const auto = autoSignIn(value.autoUrl);
  const code = typeof value.userCode === "string" && value.userCode.trim() ? value.userCode.trim() : undefined;
  const way: SignInStarted["way"] = code
    ? { kind: "code", code }
    : value.needsCode === true || !(auto && value.callbackPort === auto.port)
      ? { kind: "paste" }
      : { kind: "approve" };
  return {
    account: value.account,
    loginId: value.loginId,
    url,
    way,
    expiresAtMs: typeof value.expiresAtMs === "number" ? value.expiresAtMs : Number.POSITIVE_INFINITY,
    added: value.added === true,
  };
}

/** `account.sign_in.finish`'s answer: whether it signed in. */
export function parseSignInFinish(reply: unknown): SignInFinishWire | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const value = reply as Partial<Record<keyof SignInFinishWire, unknown>>;
  if (typeof value.signedIn !== "boolean") return undefined;
  return { signedIn: value.signedIn, account: typeof value.account === "string" ? value.account : "" };
}

/** A list row, or undefined when it is not one. */
export function parseAccountRow(raw: unknown): AccountRowWire | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const value = raw as Partial<Record<keyof AccountRowWire, unknown>>;
  if (typeof value.id !== "string" || typeof value.name !== "string") return undefined;
  if (!ACCOUNT_FAMILIES.includes(value.family as AccountFamily)) return undefined;
  return {
    id: value.id,
    family: value.family as AccountFamily,
    name: value.name,
    ...(typeof value.email === "string" && value.email ? { email: value.email } : {}),
    ...(typeof value.plan === "string" && value.plan ? { plan: value.plan } : {}),
    signedIn: value.signedIn === true,
    default: value.default === true,
    builtin: value.builtin === true,
  };
}

/** The refusal's `reason` (top level, or under `data` or `details`), as the card's failure. */
export function signInFailure(error: unknown): SignInFailure {
  const value = (error ?? {}) as { reason?: unknown; data?: { reason?: unknown }; details?: { reason?: unknown } };
  const reason = value.reason ?? value.data?.reason ?? value.details?.reason;
  switch (reason) {
    case "not_installed":
    case "cli_missing":
      return "not_installed";
    case "expired":
    case "unknown_login":
      return "expired";
    case "cancelled":
    case "access_denied":
      return "cancelled";
    case "shared_machine":
      return "shared_machine";
    default:
      return "other";
  }
}

/** What the card draws. The code is in `waiting` only, for the card's own render. */
export type SignInView =
  | { state: "starting" }
  | { state: "waiting"; way: SignInStarted["way"]; copied: boolean; url: string; busy?: boolean }
  | { state: "signedIn"; account: string | null }
  | { state: "expired" }
  | { state: "failed"; reason: Exclude<SignInFailure, "not_installed" | "expired"> }
  | { state: "notInstalled" };

/** The view a failure shows: its own state for a missing CLI or an expired code. */
export function failedView(failure: SignInFailure): SignInView {
  if (failure === "not_installed") return { state: "notInstalled" };
  if (failure === "expired") return { state: "expired" };
  return { state: "failed", reason: failure };
}

/** The provider's name, as the person knows it. Product names: never translated. */
export const FAMILY_BRAND: Record<AccountFamily, string> = { github: "GitHub", codex: "ChatGPT", claude: "Claude" };
/** The CLI that signs in, for "isn't installed". Product names. */
export const FAMILY_CLI: Record<AccountFamily, string> = {
  github: "GitHub CLI",
  codex: "Codex",
  claude: "Claude Code",
};

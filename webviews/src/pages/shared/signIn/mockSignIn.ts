// l10n-allow-file: mock daemon replies, not shipped UI.
// The daemon's in-place sign-in as the mock hosts answer it (Settings' and onboarding's mocks run
// this one, so the browser dev loop, the tests and the gallery see the same replies a host gives):
// a start lists a new account (signed out) and answers its code, a finish signs it in, a cancel
// drops a new one again. Codes are made up; names are example.com.
import {
  ACCOUNT_ACTIONS,
  type AccountFamily,
  type AccountRowWire,
  type AccountRunParams,
  type AccountRunReply,
  type SignInStartWire,
} from "./accountSignIn";

/** Where the mock keeps the account rows (`signInAccounts`) and tells its page they changed. */
export type MockSignInHost = {
  rows(): AccountRowWire[];
  set(next: AccountRowWire[]): void;
};

export class MockAccountSignIn {
  /** A sign-in's finish waits for this when set (tests and the gallery hold the code on screen). */
  hold: Promise<void> | null = null;
  /** The next sign-in start is refused with this reason (`not_installed`, `shared_machine`, ...). */
  refusal: string | null = null;
  /** How long a started sign-in's code lasts (tests shorten it to see the expiry). */
  expiresInMs = 15 * 60_000;
  /** An older daemon (no `_acpmux/account/sign_in`): a start answers `{}`, as the host does on
   * method not found, and the page runs its terminal sign-in. */
  olderDaemon = false;
  /** With `olderDaemon`: the host runs the start's terminal sign-in itself and answers
   * `{ terminal: true }` (SettingsHarnesses+AccountSignIn.swift); without it, an older host's `{}`. */
  hostRunsTerminal = false;
  /** A start answers only once this settles (tests see the card while it is starting). */
  startHold: Promise<void> | null = null;
  /** Every start that reached the mock. */
  starts = 0;
  /** Every cancel that reached the mock, by login id. */
  cancelled: string[] = [];
  private started = 0;
  private logins = new Map<string, { account: string; family: AccountFamily; added: boolean }>();

  constructor(private readonly host: MockSignInHost) {}

  /** One ACCOUNT_ACTIONS gesture; anything else answers `{}`. */
  async run(run: AccountRunParams & { name?: string }): Promise<AccountRunReply> {
    const rows = this.host.rows();
    const set = (next: AccountRowWire[]) => this.host.set(next);
    switch (run.action) {
      case ACCOUNT_ACTIONS.start: {
        this.starts += 1;
        if (this.startHold) await this.startHold;
        if (this.olderDaemon) return this.hostRunsTerminal ? { terminal: true } : {};
        if (this.refusal) {
          const reason = this.refusal;
          this.refusal = null;
          return { error: "The sign-in did not start.", reason };
        }
        const existing = rows.find((row) => row.id === run.account);
        const family = existing?.family ?? run.family ?? "codex";
        const added = !existing;
        const account = existing?.id ?? `${family}-${rows.filter((row) => row.family === family).length + 1}`;
        if (added) {
          const row: AccountRowWire = {
            id: account,
            family,
            name: run.name ?? account,
            signedIn: false,
            default: false,
            builtin: false,
          };
          set([...rows, row]);
        }
        const loginId = `login-${++this.started}`;
        this.logins.set(loginId, { account, family, added });
        const expiresAtMs = Date.now() + this.expiresInMs;
        const signIn: SignInStartWire =
          family === "claude"
            ? {
                account,
                loginId,
                url: "https://claude.ai/oauth/authorize?code=true",
                needsCode: true,
                expiresAtMs,
                added,
              }
            : family === "github"
              ? {
                  account,
                  loginId,
                  url: "https://github.com/login/device",
                  userCode: "WDJB-MJHT",
                  needsCode: false,
                  expiresAtMs,
                  added,
                }
              : {
                  account,
                  loginId,
                  url: "https://auth.openai.com/codex/device",
                  userCode: "K7QX-29PF",
                  needsCode: false,
                  expiresAtMs,
                  added,
                };
        return { signIn };
      }
      case ACCOUNT_ACTIONS.finish: {
        const login = run.loginId ? this.logins.get(run.loginId) : undefined;
        if (!login) return { error: "That sign-in has ended.", reason: "expired" };
        if (this.hold) await this.hold;
        if (!this.logins.has(run.loginId!)) return { error: "The sign-in was cancelled.", reason: "cancelled" };
        this.logins.delete(run.loginId!);
        const current = this.host.rows();
        const first = !current.some((row) => row.family === login.family && row.signedIn && row.id !== login.account);
        const name = login.family === "github" ? "octocat" : `${login.account}@example.com`;
        set(
          current.map((row) =>
            row.id === login.account
              ? {
                  ...row,
                  signedIn: true,
                  name: row.builtin ? row.name : name,
                  email: row.email ?? name,
                  default: row.default || first,
                }
              : row,
          ),
        );
        return { finished: { signedIn: true, account: name } };
      }
      case ACCOUNT_ACTIONS.cancel: {
        const login = run.loginId ? this.logins.get(run.loginId) : undefined;
        if (run.loginId) {
          this.cancelled.push(run.loginId);
          this.logins.delete(run.loginId);
        }
        if (login?.added) set(rows.filter((row) => row.id !== login.account));
        return {};
      }
      case ACCOUNT_ACTIONS.switch: {
        const family = rows.find((row) => row.id === run.account)?.family;
        set(rows.map((row) => (row.family === family ? { ...row, default: row.id === run.account } : row)));
        return {};
      }
      case ACCOUNT_ACTIONS.signOut:
        set(rows.map((row) => (row.id === run.account ? { ...row, signedIn: false } : row)));
        return {};
      case ACCOUNT_ACTIONS.remove:
        set(rows.filter((row) => row.id !== run.account));
        return {};
    }
    return {};
  }
}

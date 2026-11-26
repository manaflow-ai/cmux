// Wire types of the CodeRouter page (`cmux.coderouter.*`, plans/cmux-next/coderouter.md and
// first-party-apps/coderouter/README.md "Proposed operations"). The Mac host serves them from its
// accounts service (CodeRouterAppOps); no row carries an email or a secret: accounts are opaque
// `acct_…` handles with a redacted label.

/** `cmux.coderouter.status`: cmux sign-in and router health. Works signed out. */
export interface CodeRouterStatus {
  signed_in: boolean;
  refreshing?: boolean;
  /** `personal` or a team; null signed out. */
  scope: string | null;
  /** `ok`, `signed_out`, or the router's own word. */
  health: string;
}

/** One account CodeRouter holds (inside a detected provider row). */
export interface LinkedAccount {
  id: string;
  account: string;
  label: string;
  /** `active`, `refreshing`, `expired`, `broken`, `disabled`. */
  state: string;
  /** `private` or `team`. */
  visibility: string | null;
}

/** `cmux.coderouter.detect`: one provider row, presence only (detection never reads a secret). */
export interface ProviderRow {
  provider: string;
  name: string;
  /** `signed_in`, `expired`, `missing`, `unknown`; null while detecting. */
  status: string | null;
  account: string | null;
  label: string | null;
  plan: string | null;
  /** `idle`, `detecting`, `reauthenticating`, `connecting`, `removing`. */
  phase: string;
  can_connect: boolean;
  linkable: boolean;
  linked: LinkedAccount[];
}

export interface DetectResult {
  providers: ProviderRow[];
}

export const CodeRouterOps = {
  status: "cmux.coderouter.status",
  detect: "cmux.coderouter.detect",
  keys: "cmux.coderouter.keys.list",
  /** Sends a local sign-in to CodeRouter; the host shows its native sheet first. */
  connect: "cmux.coderouter.accounts.connect",
  /** Native UI op: runs one of the page's allowed registry actions as the user. */
  actionRun: "cmux.app.action.run",
} as const;

/** The registry actions the page runs (the host's allowlist for cmux.coderouter). */
export const CodeRouterActions = {
  signIn: "palette.auth.signIn",
  reauthenticate: "accounts.reauthenticate",
  refresh: "accounts.refresh",
} as const;

/** Codes that mean "this build has no such op": the page says "Not available", never an error. */
export const UNAVAILABLE_CODES = new Set([
  "cmux.protocol.unknown_op",
  "cmux.operation.unsupported",
  "operation.unsupported",
]);

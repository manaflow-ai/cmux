/**
 * One read for every account a team has.
 *
 * A team's accounts live in three stores: the coderouter account table
 * (Codex and OpenCode, with provider quota), the Claude upstream table, and
 * the hosted Subrouter vault that the cmux app writes to. Each surface used to
 * fan out to those stores itself, which is why `cr accounts` listed four
 * accounts while the dashboard listed nine. Both now call this function, so a
 * new store is added in one place and every surface gets it.
 *
 * The three reads run concurrently and fail independently: a store that is
 * down, absent, or unreachable with the caller's credentials is reported in
 * `sources` and never hides the accounts that did load.
 */
import {
  createHostedSubrouterClient,
  HostedSubrouterError,
  type HostedTeam,
} from "../subrouter/hostedClient";
import type { SubrouterAccount } from "../subrouter/types";
import { hostedSubrouterCutoverReadyForTeam } from "../subrouter/cutover";
import { listClaudeAccounts, type ClaudeAccountDescription } from "./claudeUpstream";
import { accountsWithUsage } from "./usage";
import type { CodeRouterAccountSummary } from "./types";

export type TeamAccountSource = "native" | "claude" | "shared";

/**
 * Whether the caller can read the hosted vault. The vault authenticates the
 * end user itself, so a route token alone cannot read it; that is a missing
 * source, not an error.
 */
export type VaultAccess =
  | { readonly kind: "none" }
  | {
    readonly kind: "session";
    readonly team: HostedTeam;
    readonly accessToken: string;
  };

export type TeamAccountSourceStatus =
  | { readonly kind: "ok"; readonly count: number }
  | { readonly kind: "error" }
  | {
    readonly kind: "unavailable";
    readonly reason: "no_session" | "not_configured" | "migration_pending";
  };

/**
 * One account, normalized across the three stores.
 *
 * `usage` is the provider's own quota document, passed through verbatim for
 * the client to render; nothing here interprets it.
 */
type TeamAccountBase = {
  readonly id: string;
  readonly label: string;
  readonly state: "active" | "disabled" | "refreshing" | "expired" | "broken";
  /** Whether coderouter's data plane can route a request to this account. */
  readonly routable: boolean;
  /**
   * Sessions bound to this account with recent traffic. Only the native store
   * binds sessions, so the other stores report null rather than a false zero.
   */
  readonly activeSessions: number | null;
};

export type TeamAccount =
  | (TeamAccountBase & {
    readonly source: "native";
    readonly provider: CodeRouterAccountSummary["provider"];
    readonly native: CodeRouterAccountSummary;
    readonly usage?: unknown;
    readonly usageError?: string;
  })
  | (TeamAccountBase & {
    readonly source: "claude";
    readonly provider: "claude";
    readonly claude: ClaudeAccountDescription;
  })
  | (TeamAccountBase & {
    readonly source: "shared";
    // Its own provider name, not the vault account's kind: a client that
    // groups by provider must not file these under Codex, where they would
    // read as routing capacity. The kind stays on `shared`.
    readonly provider: "shared";
    readonly shared: SubrouterAccount;
  });

export type TeamAccountsResult = {
  readonly accounts: readonly TeamAccount[];
  readonly sources: Readonly<
    Record<TeamAccountSource, TeamAccountSourceStatus>
  >;
  readonly usageAsOf: string;
  readonly usageGeneratedAtMs: number;
  readonly cacheMaxAgeSeconds: number;
  readonly timing: {
    readonly rdsMs: number;
    readonly providerMs: number;
    readonly vaultMs: number;
  };
};

export type TeamAccountsDependencies = {
  readonly nativeAccounts: typeof accountsWithUsage;
  readonly claudeAccounts: typeof listClaudeAccounts;
  readonly vaultReady: typeof hostedSubrouterCutoverReadyForTeam;
  readonly vaultClient: typeof createHostedSubrouterClient;
};

const defaultDependencies: TeamAccountsDependencies = {
  nativeAccounts: accountsWithUsage,
  claudeAccounts: listClaudeAccounts,
  vaultReady: hostedSubrouterCutoverReadyForTeam,
  vaultClient: createHostedSubrouterClient,
};

type NativeRead = {
  readonly accounts: readonly TeamAccount[];
  readonly status: TeamAccountSourceStatus;
  readonly usageAsOf: string;
  readonly usageGeneratedAtMs: number;
  readonly cacheMaxAgeSeconds: number;
  readonly rdsMs: number;
  readonly providerMs: number;
};

export async function listTeamAccounts(
  input: {
    readonly teamId: string;
    readonly vault: VaultAccess;
  },
  dependencies: TeamAccountsDependencies = defaultDependencies,
): Promise<TeamAccountsResult> {
  const vaultStartedAt = performance.now();
  const [native, claude, shared] = await Promise.all([
    readNative(input.teamId, dependencies),
    readClaude(input.teamId, dependencies),
    readShared(input.vault, dependencies),
  ]);
  return {
    accounts: [...native.accounts, ...claude.accounts, ...shared.accounts],
    sources: {
      native: native.status,
      claude: claude.status,
      shared: shared.status,
    },
    usageAsOf: native.usageAsOf,
    usageGeneratedAtMs: native.usageGeneratedAtMs,
    cacheMaxAgeSeconds: native.cacheMaxAgeSeconds,
    timing: {
      rdsMs: native.rdsMs,
      providerMs: native.providerMs,
      vaultMs: performance.now() - vaultStartedAt,
    },
  };
}

async function readNative(
  teamId: string,
  dependencies: TeamAccountsDependencies,
): Promise<NativeRead> {
  const now = Date.now();
  try {
    const result = await dependencies.nativeAccounts(teamId);
    const accounts = result.accounts.map((account): TeamAccount => {
      const { usage, usageError, ...summary } = account as
        & CodeRouterAccountSummary
        & { usage?: unknown; usageError?: string };
      return {
        source: "native",
        id: summary.id,
        provider: summary.provider,
        label: summary.label,
        state: summary.state,
        routable: summary.state === "active",
        activeSessions: summary.activeSessions,
        native: summary,
        ...(usage === undefined ? {} : { usage }),
        ...(usageError === undefined ? {} : { usageError }),
      };
    });
    return {
      accounts,
      status: { kind: "ok", count: accounts.length },
      usageAsOf: result.usageAsOf,
      usageGeneratedAtMs: result.usageGeneratedAtMs,
      cacheMaxAgeSeconds: result.cacheMaxAgeSeconds,
      rdsMs: result.timing.rdsMs,
      providerMs: result.timing.providerMs,
    };
  } catch {
    return {
      accounts: [],
      status: { kind: "error" },
      usageAsOf: new Date(now).toISOString(),
      usageGeneratedAtMs: now,
      cacheMaxAgeSeconds: 0,
      rdsMs: 0,
      providerMs: 0,
    };
  }
}

async function readClaude(
  teamId: string,
  dependencies: TeamAccountsDependencies,
): Promise<{
  readonly accounts: readonly TeamAccount[];
  readonly status: TeamAccountSourceStatus;
}> {
  try {
    const accounts = (await dependencies.claudeAccounts(teamId)).map(
      (account): TeamAccount => ({
        source: "claude",
        id: account.id,
        provider: "claude",
        label: account.label.trim() || account.identifier,
        state: account.state,
        routable: account.state === "active",
        activeSessions: null,
        claude: account,
      }),
    );
    return { accounts, status: { kind: "ok", count: accounts.length } };
  } catch {
    return { accounts: [], status: { kind: "error" } };
  }
}

async function readShared(
  vault: VaultAccess,
  dependencies: TeamAccountsDependencies,
): Promise<{
  readonly accounts: readonly TeamAccount[];
  readonly status: TeamAccountSourceStatus;
}> {
  if (vault.kind === "none") {
    return { accounts: [], status: { kind: "unavailable", reason: "no_session" } };
  }
  try {
    if (!await dependencies.vaultReady(vault.team.teamId)) {
      return {
        accounts: [],
        status: { kind: "unavailable", reason: "migration_pending" },
      };
    }
    const client = dependencies.vaultClient();
    if (!client.tenantControlConfigured) {
      return {
        accounts: [],
        status: { kind: "unavailable", reason: "not_configured" },
      };
    }
    const tenant = await client.exchangeTeam(vault.accessToken, vault.team);
    const accounts = (await client.listAccounts(tenant.tenantKey)).map(
      (account): TeamAccount => ({
        source: "shared",
        id: account.id,
        provider: "shared",
        label: account.label ?? account.id,
        state: account.health?.ok === false ? "broken" : "active",
        // The vault serves the cmux app's own proxy. coderouter's data plane
        // never selects these accounts, so counting them as routable capacity
        // would overstate what `cr` can use.
        routable: false,
        activeSessions: null,
        shared: account,
      }),
    );
    return { accounts, status: { kind: "ok", count: accounts.length } };
  } catch {
    return { accounts: [], status: { kind: "error" } };
  }
}

/**
 * Account ids the removal path will act on. The database stores use UUIDs and
 * the vault uses the account's own label (an email in practice), so the shape
 * cannot be pinned further. Path separators, whitespace, and control
 * characters are rejected: no store issues them, and forwarding them would let
 * a caller reach for another resource in an upstream path.
 */
export function isTeamAccountId(value: string): boolean {
  return value.length > 0 && value.length <= 200 &&
    !/[\s/\\]/.test(value) && !/[\u0000-\u001f\u007f]/.test(value) &&
    !value.includes("..");
}

/** UUID v1-v5, the id shape of both database-backed stores. */
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type TeamAccountRemoval =
  | {
    readonly removed: true;
    readonly source: TeamAccountSource;
    readonly lastAccount: boolean;
    readonly legacyCleanupPending: boolean;
  }
  | { readonly removed: false };

/**
 * Remove one account from whichever store owns its id.
 *
 * Callers hold an account id, not a store name: the CLI reads one list and
 * removes from it. Resolving the store here is what lets there be one removal
 * endpoint, and it keeps older clients correct, since they send ids from every
 * store to this one path.
 */
export async function removeTeamAccount(input: {
  readonly teamId: string;
  readonly accountId: string;
  readonly vault: VaultAccess;
  readonly vaultClient?: typeof createHostedSubrouterClient;
  readonly removeNative: (
    teamId: string,
    accountId: string,
  ) => Promise<{
    readonly removed: boolean;
    readonly lastAccount: boolean;
    readonly legacyCleanupPending: boolean;
  }>;
  readonly removeClaude: (
    teamId: string,
    accountId: string,
  ) => Promise<{ readonly removed: boolean }>;
}): Promise<TeamAccountRemoval> {
  if (UUID.test(input.accountId)) {
    const native = await input.removeNative(input.teamId, input.accountId);
    if (native.removed) {
      return {
        removed: true,
        source: "native",
        lastAccount: native.lastAccount,
        legacyCleanupPending: native.legacyCleanupPending,
      };
    }
    const claude = await input.removeClaude(input.teamId, input.accountId);
    if (claude.removed) {
      return {
        removed: true,
        source: "claude",
        lastAccount: false,
        legacyCleanupPending: false,
      };
    }
    return { removed: false };
  }
  return await removeSharedAccount(
    input.accountId,
    input.vault,
    input.vaultClient ?? createHostedSubrouterClient,
  );
}

async function removeSharedAccount(
  accountId: string,
  vault: VaultAccess,
  vaultClient: typeof createHostedSubrouterClient,
): Promise<TeamAccountRemoval> {
  if (vault.kind === "none") return { removed: false };
  const client = vaultClient();
  if (!client.tenantControlConfigured) return { removed: false };
  const tenant = await client.exchangeTeam(vault.accessToken, vault.team);
  try {
    await client.deleteAccount(tenant.tenantKey, accountId);
  } catch (error) {
    // An id the vault does not hold is a miss, the same as a UUID that matches
    // no row. Letting it escape would answer 503 and report an outage for what
    // is only a stale id.
    if (error instanceof HostedSubrouterError && error.status === 404) {
      return { removed: false };
    }
    throw error;
  }
  return {
    removed: true,
    source: "shared",
    lastAccount: false,
    legacyCleanupPending: false,
  };
}

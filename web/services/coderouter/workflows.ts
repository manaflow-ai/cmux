import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { encryptSecret } from "./crypto";
import {
  CoderouterConfigurationError,
  coderouterWorkflowErrorCause,
  type CoderouterWorkflowError,
} from "./errors";
import { mintCallerKey, sha256Hex } from "./keys";
import {
  CoderouterBillingGateway,
  CoderouterBillingGatewayLive,
  type BillingCustomer,
} from "./billing";
import {
  CoderouterOAuthConnect,
  CoderouterOAuthConnectLive,
  type ImportedOauthChain,
} from "./oauthConnect";
import { seedOauthFromImportedChain } from "./oauthConnect";
import {
  CoderouterRepository,
  CoderouterRepositoryLive,
  parsePoolName,
  poolName,
  type CoderouterCredentialRow,
  type CoderouterKeyRow,
  type UsageSummaryRow,
} from "./repository";
import {
  CoderouterWorkerSync,
  CoderouterWorkerSyncLive,
} from "./workerSync";
import type { CredentialClass, Family, KeyPolicy, PoolConfig, UsageIngest } from "./types";

export const CoderouterWorkflowLive = Layer.mergeAll(
  CoderouterRepositoryLive,
  CoderouterBillingGatewayLive,
  CoderouterWorkerSyncLive,
  CoderouterOAuthConnectLive,
);

export async function runCoderouterWorkflow<A>(
  program: Effect.Effect<
    A,
    CoderouterWorkflowError,
    CoderouterRepository | CoderouterBillingGateway | CoderouterWorkerSync | CoderouterOAuthConnect
  >,
): Promise<A> {
  try {
    return await Effect.runPromise(program.pipe(Effect.provide(CoderouterWorkflowLive)));
  } catch (err) {
    throw coderouterWorkflowErrorCause(err) ?? err;
  }
}

export function listKeys(teamId: string) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    return yield* repo.listKeys(teamId);
  });
}

export function createKey(input: {
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
  readonly name: string;
  readonly policy: KeyPolicy;
}) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    const secret = process.env.CODEROUTER_KEY_SIGNING_SECRET?.trim();
    if (!secret) {
      return yield* Effect.fail(
        new CoderouterConfigurationError("createKey", "CODEROUTER_KEY_SIGNING_SECRET is not configured."),
      );
    }
    const minted = yield* Effect.promise(() => mintCallerKey({ teamId: input.teamId, secret }));
    const secretHash = yield* Effect.promise(() => sha256Hex(minted.key));
    const row = yield* repo.createKey({
      kid: minted.kid,
      teamId: input.teamId,
      name: input.name,
      secretHash,
      policy: input.policy,
    });
    yield* syncAllTeamPools(input.teamId, input.billingCustomer);
    return { key: minted.key, row };
  });
}

export function revokeKey(input: {
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
  readonly keyId: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    const row = yield* repo.revokeKey(input.teamId, input.keyId);
    yield* syncAllTeamPools(input.teamId, input.billingCustomer);
    return row;
  });
}

export function listCredentials(teamId: string) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    return yield* repo.listCredentials(teamId);
  });
}

export function addByokCredential(input: {
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
  readonly family: Family;
  readonly label?: string | null;
  readonly apiKey: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    const encryptedSecret = yield* Effect.tryPromise({
      try: () => encryptSecret(input.apiKey),
      catch: (cause) =>
        cause instanceof CoderouterConfigurationError
          ? cause
          : new CoderouterConfigurationError("encryptByok", "Could not encrypt coderouter API key."),
    });
    const row = yield* repo.createCredential({
      teamId: input.teamId,
      family: input.family,
      billingCustomerType: input.billingCustomer.type,
      kind: "api_key",
      class: "byok",
      label: input.label,
      encryptedSecret,
    });
    yield* syncPoolForFamily(input.teamId, input.family, input.billingCustomer);
    return row;
  });
}

export function disableCredential(input: {
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
  readonly credentialId: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    const row = yield* repo.disableCredential(input.teamId, input.credentialId);
    const family = yield* familyForCredential(input.teamId, row);
    yield* syncPoolForFamily(input.teamId, family, input.billingCustomer);
    return row;
  });
}

export function startAnthropicConnect() {
  return Effect.gen(function* () {
    const oauth = yield* CoderouterOAuthConnect;
    return yield* oauth.startAnthropic();
  });
}

export function completeAnthropicConnect(input: {
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
  readonly pastedCode: string;
  readonly stateCookie: string | null;
}) {
  return Effect.gen(function* () {
    const oauth = yield* CoderouterOAuthConnect;
    const chain = yield* oauth.completeAnthropic({
      pastedCode: input.pastedCode,
      stateCookie: input.stateCookie,
    });
    return yield* createOauthCredentialFromChain({
      teamId: input.teamId,
      billingCustomer: input.billingCustomer,
      chain,
      label: "Anthropic OAuth",
    });
  });
}

export function startOpenAIConnect() {
  return Effect.gen(function* () {
    const oauth = yield* CoderouterOAuthConnect;
    return yield* oauth.startOpenAI();
  });
}

export function pollOpenAIConnect(input: {
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
  readonly deviceCode: string;
}) {
  return Effect.gen(function* () {
    const oauth = yield* CoderouterOAuthConnect;
    const result = yield* oauth.pollOpenAI(input.deviceCode);
    if (result.status === "pending") return result;
    const credential = yield* createOauthCredentialFromChain({
      teamId: input.teamId,
      billingCustomer: input.billingCustomer,
      chain: result.chain,
      label: "OpenAI OAuth",
    });
    return { status: "complete" as const, credential };
  });
}

export function importOauthCredential(input: {
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
  readonly chain: ImportedOauthChain;
  readonly label?: string | null;
}) {
  return createOauthCredentialFromChain(input);
}

export function usageSummary(input: {
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
  readonly days: number;
}) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    const billing = yield* CoderouterBillingGateway;
    const [rows, balanceMicros] = yield* Effect.all([
      repo.usageSummary(input.teamId, input.days),
      billing.currentBalanceMicros(input.billingCustomer),
    ]);
    return { rows, balanceMicros };
  });
}

export function poolConfigForName(poolNameValue: string) {
  return Effect.gen(function* () {
    const parsed = parsePoolName(poolNameValue);
    if (!parsed) {
      return yield* Effect.fail(new CoderouterConfigurationError("poolConfig", "Invalid coderouter pool id."));
    }
    const repo = yield* CoderouterRepository;
    const pool = yield* repo.poolForName(poolNameValue);
    return yield* buildPoolConfig({
      teamId: parsed.teamId,
      family: parsed.family,
      billingCustomer: { type: pool.billingCustomerType as "team" | "user", id: parsed.teamId },
    });
  });
}

export function ingestUsage(input: {
  readonly usage: UsageIngest;
  readonly billingCustomer?: BillingCustomer;
}) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    const billing = yield* CoderouterBillingGateway;
    const parsed = parsePoolName(input.usage.poolId);
    if (!parsed) {
      return yield* Effect.fail(new CoderouterConfigurationError("usageIngest", "Invalid coderouter pool id."));
    }
    const pool = yield* repo.poolForName(input.usage.poolId);
    const customer = input.billingCustomer ?? { type: pool.billingCustomerType as "team" | "user", id: parsed.teamId };
    const inserted = yield* repo.insertUsageEvents({
      teamId: parsed.teamId,
      events: input.usage.events,
    });
    if (inserted.managedCostMicros > 0) {
      yield* billing.debitUsage(customer, inserted.managedCostMicros);
    }
    yield* repo.applyStatusUpdates({
      poolName: input.usage.poolId,
      updates: input.usage.statusUpdates ?? [],
    });
    const balanceMicros = yield* billing.currentBalanceMicros(customer);
    return { balanceMicros, inserted };
  });
}

function createOauthCredentialFromChain(input: {
  readonly teamId: string;
  readonly billingCustomer: BillingCustomer;
  readonly chain: ImportedOauthChain;
  readonly label?: string | null;
}) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    const worker = yield* CoderouterWorkerSync;
    const row = yield* repo.createCredential({
      teamId: input.teamId,
      family: input.chain.provider,
      billingCustomerType: input.billingCustomer.type,
      kind: "oauth",
      class: "oauth",
      label: input.label,
      providerEmail: input.chain.email ?? null,
      providerAccountId: input.chain.accountId ?? null,
      meta: {},
    });
    yield* worker.seedOauth(
      poolName(input.teamId, input.chain.provider),
      seedOauthFromImportedChain(row.id, input.chain),
    );
    yield* syncPoolForFamily(input.teamId, input.chain.provider, input.billingCustomer);
    return row;
  });
}

function syncAllTeamPools(teamId: string, billingCustomer: BillingCustomer) {
  return Effect.gen(function* () {
    yield* Effect.all([
      syncPoolForFamily(teamId, "anthropic", billingCustomer),
      syncPoolForFamily(teamId, "openai", billingCustomer),
    ], { discard: true });
  });
}

function syncPoolForFamily(teamId: string, family: Family, billingCustomer: BillingCustomer) {
  return Effect.gen(function* () {
    const worker = yield* CoderouterWorkerSync;
    const config = yield* buildPoolConfig({ teamId, family, billingCustomer });
    yield* worker.syncPool(config);
  });
}

function buildPoolConfig(input: {
  readonly teamId: string;
  readonly family: Family;
  readonly billingCustomer: BillingCustomer;
}): Effect.Effect<PoolConfig, CoderouterWorkflowError, CoderouterRepository | CoderouterBillingGateway> {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    const billing = yield* CoderouterBillingGateway;
    const balanceMicros = yield* billing.currentBalanceMicros(input.billingCustomer);
    return yield* repo.buildPoolConfig({
      teamId: input.teamId,
      family: input.family,
      billingCustomerType: input.billingCustomer.type,
      balanceMicros,
      managedEnabled: billing.managedBillingEnabled(),
    });
  });
}

function familyForCredential(teamId: string, credential: CoderouterCredentialRow) {
  return Effect.gen(function* () {
    const repo = yield* CoderouterRepository;
    const pools = yield* repo.listPoolsForTeam(teamId);
    const pool = pools.find((candidate) => candidate.id === credential.poolId);
    if (!pool) {
      return yield* Effect.fail(new CoderouterConfigurationError("disableCredential", "Credential pool was not found."));
    }
    return pool.family;
  });
}

export function publicKey(row: CoderouterKeyRow) {
  return {
    id: row.id,
    name: row.name,
    policy: row.policy,
    createdAt: row.createdAt.toISOString(),
    revokedAt: row.revokedAt?.toISOString() ?? null,
    lastUsedAt: row.lastUsedAt?.toISOString() ?? null,
  };
}

export function publicCredential(row: CoderouterCredentialRow) {
  return {
    id: row.id,
    kind: row.kind,
    class: row.class,
    status: row.status,
    label: row.label,
    providerEmail: row.providerEmail,
    providerAccountId: row.providerAccountId,
    createdAt: row.createdAt.toISOString(),
    lastUsedAt: row.lastUsedAt?.toISOString() ?? null,
  };
}

export function publicUsageSummary(rows: readonly UsageSummaryRow[]) {
  return rows.map((row) => ({
    day: row.day,
    model: row.model,
    credentialClass: row.credentialClass,
    inputTokens: Number(row.inputTokens),
    outputTokens: Number(row.outputTokens),
    cacheReadTokens: Number(row.cacheReadTokens),
    cacheWriteTokens: Number(row.cacheWriteTokens),
    costMicros: Number(row.costMicros),
    requests: Number(row.requests),
  }));
}

export function allowedClassesPolicy(value: readonly CredentialClass[] | undefined): KeyPolicy {
  if (!value || value.length === 0) return {};
  return { allowedClasses: [...new Set(value)] };
}

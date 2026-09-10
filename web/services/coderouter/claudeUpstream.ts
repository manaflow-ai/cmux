// Per-team Claude upstream accounts for the coderouter `/v1/messages` leg.
//
// A team holds any number of accounts of any kind (Anthropic API key, Claude
// Code OAuth token, Bedrock credentials). The data plane picks one healthy
// account per request: a client with a stable key (its Cloud VM, or its route
// token) is pinned to the same account by rendezvous hashing so Anthropic's
// per-organization prompt cache keeps hitting, and a 429/401/5xx puts that
// account in cooldown and moves the client to the next one. Secrets are KMS
// envelope-encrypted like `coderouter_credentials`; the AAD and KMS context
// bind the ciphertext to (team, account id, kind) so a row cannot be replayed
// for another team or account.
import { createHash, randomUUID } from "node:crypto";
import { and, asc, eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { runWithCloudDbQuerySignal } from "../../db/queryScope";
import { coderouterClaudeAccounts } from "../../db/schema";
import {
  decryptSecretEnvelope,
  encryptSecretEnvelope,
  type CredentialKeyService,
  type SecretEnvelope,
} from "./encryption";

export type ClaudeUpstreamKind =
  | "anthropic_api_key"
  | "anthropic_oauth"
  | "bedrock";

export const CLAUDE_UPSTREAM_KINDS: readonly ClaudeUpstreamKind[] = [
  "anthropic_api_key",
  "anthropic_oauth",
  "bedrock",
];

export type ClaudeAccountState = "active" | "disabled";

export type ClaudeUpstreamSecret =
  | { readonly kind: "anthropic_api_key"; readonly apiKey: string }
  | { readonly kind: "anthropic_oauth"; readonly token: string }
  | {
    readonly kind: "bedrock";
    readonly accessKeyId: string;
    readonly secretAccessKey: string;
    readonly sessionToken?: string;
  };

/** Non-secret settings stored next to the envelope. */
export type ClaudeUpstreamConfig = {
  /** Bedrock only. */
  readonly region?: string;
  /** Bedrock only: Anthropic model id -> Bedrock model id overrides. */
  readonly modelIds?: Readonly<Record<string, string>>;
};

/** One decrypted account, as the data plane uses it. Server-only. */
export type ClaudeUpstream = {
  readonly accountId: string;
  readonly teamId: string;
  readonly kind: ClaudeUpstreamKind;
  readonly label: string;
  readonly secret: ClaudeUpstreamSecret;
  readonly config: ClaudeUpstreamConfig;
  readonly updatedAt: Date;
};

/** What the dashboard, the CLI, and the GET route see. Never carries a secret. */
export type ClaudeAccountDescription = {
  readonly id: string;
  readonly kind: ClaudeUpstreamKind;
  readonly label: string;
  readonly identifier: string;
  readonly region: string | null;
  readonly modelIds: Readonly<Record<string, string>>;
  readonly state: ClaudeAccountState;
  readonly cooldownUntil: string | null;
  readonly lastFailureCode: string | null;
  readonly lastUsedAt: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
};

/** Kept for clients that still read one `upstream` object. */
export type ClaudeUpstreamDescription = ClaudeAccountDescription;

export type ClaudeUpstreamInput =
  | { readonly kind: "anthropic_api_key"; readonly apiKey: string; readonly label?: string }
  | { readonly kind: "anthropic_oauth"; readonly token: string; readonly label?: string }
  | {
    readonly kind: "bedrock";
    readonly region: string;
    readonly accessKeyId: string;
    readonly secretAccessKey: string;
    readonly sessionToken?: string;
    readonly modelIds?: Readonly<Record<string, string>>;
    readonly label?: string;
  };

export type ClaudeAccountPatch = {
  readonly label?: string;
  readonly state?: ClaudeAccountState;
};

export type ClaudeAccountRow = {
  readonly id: string;
  readonly teamId: string;
  readonly kind: ClaudeUpstreamKind;
  readonly label: string;
  /** Empty on rows migrated from the single-upstream table until backfilled. */
  readonly identifier: string;
  readonly state: ClaudeAccountState;
  readonly cooldownUntil: Date | null;
  readonly lastUsedAt: Date | null;
  readonly lastFailureCode: string | null;
  readonly aadVersion: 1 | 2;
  readonly config: Record<string, unknown>;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly updatedAt: Date;
} & SecretEnvelope;

export type ClaudeAccountInsert = Omit<ClaudeAccountRow, "createdAt" | "updatedAt">;

export type ClaudeAccountStore = {
  /** Every account of the team, oldest first. */
  list(teamId: string, signal?: AbortSignal): Promise<readonly ClaudeAccountRow[]>;
  insert(row: ClaudeAccountInsert): Promise<ClaudeAccountRow>;
  update(
    teamId: string,
    accountId: string,
    patch: { readonly label?: string; readonly state?: ClaudeAccountState; readonly identifier?: string },
  ): Promise<ClaudeAccountRow | null>;
  remove(teamId: string, accountId: string): Promise<boolean>;
  removeAll(teamId: string): Promise<number>;
  markCooldown(accountId: string, until: Date, failureCode: string, signal?: AbortSignal): Promise<void>;
  touchUsed(accountId: string, at: Date, signal?: AbortSignal): Promise<void>;
};

export type ClaudeUpstreamDependencies = {
  readonly store: ClaudeAccountStore;
  readonly keys?: CredentialKeyService;
  readonly keyId?: string;
  readonly now?: () => Date;
  readonly newId?: () => string;
};

export type ClaudeSelectionInput = {
  /**
   * Stable per-client key (Cloud VM id, else the route token). Clients with
   * the same key land on the same account while it stays healthy.
   */
  readonly stickyKey: string | null;
  /** Accounts already tried for this request. */
  readonly excludedAccountIds?: readonly string[];
  /** Request-scoped cancellation for database and credential selection work. */
  readonly signal?: AbortSignal;
};

export type ClaudeSelection =
  | { readonly kind: "selected"; readonly upstream: ClaudeUpstream; readonly total: number; readonly healthy: number }
  /** The team has no accounts at all. */
  | { readonly kind: "none" }
  /** Every remaining account is disabled, cooling down, or already tried. */
  | { readonly kind: "exhausted"; readonly total: number; readonly retryAfterSeconds: number };

const ANTHROPIC_API_KEY = /^sk-ant-(?!oat)[A-Za-z0-9_-]{20,500}$/;
const ANTHROPIC_OAUTH_TOKEN = /^sk-ant-oat01-[A-Za-z0-9_-]{20,1000}$/;
const AWS_ACCESS_KEY_ID = /^(?:AKIA|ASIA)[A-Z0-9]{16}$/;
const AWS_SECRET_ACCESS_KEY = /^[A-Za-z0-9/+]{40}$/;
const AWS_SESSION_TOKEN = /^[A-Za-z0-9/+=]{16,4096}$/;
// us-east-1, ap-southeast-2, us-gov-west-1, eu-central-1.
export const AWS_REGION = /^[a-z]{2}(?:-[a-z]+)+-\d$/;
const ANTHROPIC_MODEL_ID = /^claude-[a-z0-9.-]{1,64}$/;
const BEDROCK_MODEL_ID =
  /^(?:(?:global|us|eu|apac|jp|au|ca)\.)?anthropic\.claude-[a-z0-9.:-]{1,96}$/;
const MAX_MODEL_OVERRIDES = 32;
export const MAX_ACCOUNT_LABEL_CHARS = 64;
const ACCOUNT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Cooldown bounds mirror `markAccountCooldown` on the Codex side. */
const MIN_COOLDOWN_MS = 1_000;
const MAX_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000;
const DEFAULT_EXHAUSTED_RETRY_SECONDS = 15;

export function isClaudeAccountId(value: unknown): value is string {
  return typeof value === "string" && ACCOUNT_ID.test(value);
}

export function parseClaudeUpstreamInput(value: unknown): ClaudeUpstreamInput | null {
  if (!isRecord(value)) return null;
  const label = parseLabel(value.label);
  if (label === null) return null;
  const withLabel = <T extends object>(input: T): T & { label?: string } =>
    label ? { ...input, label } : input;
  switch (value.kind) {
    case "anthropic_api_key": {
      const apiKey = trimmed(value.apiKey);
      return apiKey && ANTHROPIC_API_KEY.test(apiKey)
        ? withLabel({ kind: "anthropic_api_key" as const, apiKey })
        : null;
    }
    case "anthropic_oauth": {
      const token = trimmed(value.token);
      return token && ANTHROPIC_OAUTH_TOKEN.test(token)
        ? withLabel({ kind: "anthropic_oauth" as const, token })
        : null;
    }
    case "bedrock": {
      const region = trimmed(value.region);
      const accessKeyId = trimmed(value.accessKeyId);
      const secretAccessKey = trimmed(value.secretAccessKey);
      const sessionToken = trimmed(value.sessionToken);
      if (
        !region || !AWS_REGION.test(region) ||
        !accessKeyId || !AWS_ACCESS_KEY_ID.test(accessKeyId) ||
        !secretAccessKey || !AWS_SECRET_ACCESS_KEY.test(secretAccessKey) ||
        (value.sessionToken !== undefined && value.sessionToken !== "" &&
          (!sessionToken || !AWS_SESSION_TOKEN.test(sessionToken)))
      ) {
        return null;
      }
      const modelIds = parseModelIds(value.modelIds);
      if (modelIds === null) return null;
      return withLabel({
        kind: "bedrock" as const,
        region,
        accessKeyId,
        secretAccessKey,
        ...(sessionToken ? { sessionToken } : {}),
        ...(Object.keys(modelIds).length > 0 ? { modelIds } : {}),
      });
    }
    default:
      return null;
  }
}

/** `undefined` when absent, `null` when present but invalid. */
export function parseClaudeAccountPatch(value: unknown): ClaudeAccountPatch | null {
  if (!isRecord(value)) return null;
  const patch: { label?: string; state?: ClaudeAccountState } = {};
  if (value.label !== undefined) {
    const label = parseLabel(value.label);
    if (label === null) return null;
    patch.label = label;
  }
  if (value.state !== undefined) {
    if (value.state !== "active" && value.state !== "disabled") return null;
    patch.state = value.state;
  }
  if (patch.label === undefined && patch.state === undefined) return null;
  return patch;
}

/** Empty string when absent; `null` when present but not a short single line. */
function parseLabel(value: unknown): string | null {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") return null;
  const label = value.trim();
  if (label.length > MAX_ACCOUNT_LABEL_CHARS || /[ -]/.test(label)) return null;
  return label;
}

function parseModelIds(value: unknown): Record<string, string> | null {
  if (value === undefined || value === null) return {};
  if (!isRecord(value)) return null;
  const entries = Object.entries(value);
  if (entries.length > MAX_MODEL_OVERRIDES) return null;
  const output: Record<string, string> = {};
  for (const [key, raw] of entries) {
    const target = trimmed(raw);
    if (!ANTHROPIC_MODEL_ID.test(key) || !target || !BEDROCK_MODEL_ID.test(target)) {
      return null;
    }
    output[key] = target;
  }
  return output;
}

export function createClaudeUpstreamService(dependencies: ClaudeUpstreamDependencies) {
  const { store } = dependencies;
  const now = dependencies.now ?? (() => new Date());
  const newId = dependencies.newId ?? randomUUID;

  async function decrypt(row: ClaudeAccountRow, signal?: AbortSignal): Promise<ClaudeUpstream> {
    const value = await decryptSecretEnvelope(row, {
      aad: accountAad(row),
      encryptionContext: accountEncryptionContext(row),
      keys: dependencies.keys,
      signal,
    });
    const secret = parseSecret(value, row.kind);
    if (!secret) throw new Error("decrypted coderouter claude account is invalid");
    return {
      accountId: row.id,
      teamId: row.teamId,
      kind: row.kind,
      label: row.label,
      secret,
      config: parseConfig(row.config),
      updatedAt: row.updatedAt,
    };
  }

  /** Rows migrated from the single-upstream table carry no identifier yet. */
  async function withIdentifier(row: ClaudeAccountRow): Promise<ClaudeAccountRow> {
    if (row.identifier) return row;
    const upstream = await decrypt(row);
    const identifier = maskedIdentifier(upstream.secret);
    const updated = await store.update(row.teamId, row.id, { identifier });
    return updated ?? { ...row, identifier };
  }

  async function list(teamId: string): Promise<readonly ClaudeAccountDescription[]> {
    const rows = await store.list(teamId);
    const described: ClaudeAccountDescription[] = [];
    for (const row of rows) {
      described.push(describeRow(await withIdentifier(row)));
    }
    return described;
  }

  async function add(
    teamId: string,
    stackUserId: string,
    input: ClaudeUpstreamInput,
  ): Promise<ClaudeAccountDescription> {
    if (!teamId || !stackUserId) throw new Error("invalid coderouter claude account owner");
    const secret = secretFromInput(input);
    const config = configFromInput(input);
    const id = newId();
    const identity = { id, teamId, kind: input.kind, aadVersion: 2 as const };
    const envelope = await encryptSecretEnvelope({
      aad: accountAad(identity),
      encryptionContext: accountEncryptionContext(identity),
      secret,
      keyId: dependencies.keyId,
      keys: dependencies.keys,
    });
    const row = await store.insert({
      id,
      teamId,
      kind: input.kind,
      label: input.label ?? "",
      identifier: maskedIdentifier(secret),
      state: "active",
      cooldownUntil: null,
      lastUsedAt: null,
      lastFailureCode: null,
      aadVersion: 2,
      config,
      createdBy: stackUserId,
      ...envelope,
    });
    return describeRow(row);
  }

  async function update(
    teamId: string,
    accountId: string,
    patch: ClaudeAccountPatch,
  ): Promise<ClaudeAccountDescription | null> {
    const row = await store.update(teamId, accountId, patch);
    return row ? describeRow(await withIdentifier(row)) : null;
  }

  async function remove(teamId: string, accountId: string): Promise<{ removed: boolean }> {
    return { removed: await store.remove(teamId, accountId) };
  }

  async function removeAll(teamId: string): Promise<{ removed: number }> {
    return { removed: await store.removeAll(teamId) };
  }

  /**
   * Picks the account a request should use. Healthy = active, not cooling
   * down, not already tried. A sticky key pins the client to one healthy
   * account by rendezvous hashing (each account scores the key; the highest
   * wins), so removing or cooling one account moves only that account's
   * clients. Without a key the least recently used account is chosen.
   */
  async function select(teamId: string, input: ClaudeSelectionInput): Promise<ClaudeSelection> {
    throwIfAborted(input.signal);
    const rows = await store.list(teamId, input.signal);
    throwIfAborted(input.signal);
    if (rows.length === 0) return { kind: "none" };
    const at = now();
    const excluded = new Set(input.excludedAccountIds ?? []);
    const eligible = rows.filter((row) => row.state === "active" && !excluded.has(row.id));
    const healthy = eligible.filter((row) => !row.cooldownUntil || row.cooldownUntil.getTime() <= at.getTime());
    if (healthy.length === 0) {
      return { kind: "exhausted", total: rows.length, retryAfterSeconds: retryAfter(eligible, at) };
    }
    const chosen = input.stickyKey
      ? rendezvousPick(input.stickyKey, healthy)
      : leastRecentlyUsed(healthy);
    const upstream = await decrypt(chosen, input.signal);
    throwIfAborted(input.signal);
    return { kind: "selected", upstream, total: rows.length, healthy: healthy.length };
  }

  async function cooldown(
    accountId: string,
    durationMs: number,
    failureCode: string,
    signal?: AbortSignal,
  ): Promise<void> {
    const clamped = Math.min(MAX_COOLDOWN_MS, Math.max(MIN_COOLDOWN_MS, Math.floor(durationMs)));
    await store.markCooldown(accountId, new Date(now().getTime() + clamped), failureCode, signal);
  }

  async function touchUsed(accountId: string, signal?: AbortSignal): Promise<void> {
    await store.touchUsed(accountId, now(), signal);
  }

  return { list, add, update, remove, removeAll, select, cooldown, touchUsed };
}

function retryAfter(eligible: readonly ClaudeAccountRow[], at: Date): number {
  let soonest: number | null = null;
  for (const row of eligible) {
    if (!row.cooldownUntil) continue;
    const seconds = Math.ceil((row.cooldownUntil.getTime() - at.getTime()) / 1000);
    if (soonest === null || seconds < soonest) soonest = seconds;
  }
  return Math.max(1, soonest ?? DEFAULT_EXHAUSTED_RETRY_SECONDS);
}

/** Highest-random-weight choice: stable per key, minimal reshuffle on change. */
export function rendezvousPick<T extends { readonly id: string }>(key: string, candidates: readonly T[]): T {
  let best: T | null = null;
  let bestScore = "";
  for (const candidate of candidates) {
    const score = createHash("sha256").update(`${key} ${candidate.id}`).digest("hex");
    if (best === null || score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best!;
}

function leastRecentlyUsed(rows: readonly ClaudeAccountRow[]): ClaudeAccountRow {
  return [...rows].sort((a, b) => {
    const au = a.lastUsedAt?.getTime() ?? 0;
    const bu = b.lastUsedAt?.getTime() ?? 0;
    if (au !== bu) return au - bu;
    return a.createdAt.getTime() - b.createdAt.getTime();
  })[0]!;
}

function describeRow(row: ClaudeAccountRow): ClaudeAccountDescription {
  const config = parseConfig(row.config);
  return {
    id: row.id,
    kind: row.kind,
    label: row.label,
    identifier: row.identifier,
    region: config.region ?? null,
    modelIds: config.modelIds ?? {},
    state: row.state,
    cooldownUntil: row.cooldownUntil?.toISOString() ?? null,
    lastFailureCode: row.lastFailureCode,
    lastUsedAt: row.lastUsedAt?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

/** Enough of the credential to recognise it, never enough to use it. */
export function maskedIdentifier(secret: ClaudeUpstreamSecret): string {
  switch (secret.kind) {
    case "anthropic_api_key":
      return `sk-ant-...${secret.apiKey.slice(-4)}`;
    case "anthropic_oauth":
      return `sk-ant-oat01-...${secret.token.slice(-4)}`;
    case "bedrock":
      return `${secret.accessKeyId.slice(0, 4)}...${secret.accessKeyId.slice(-4)}`;
  }
}

function secretFromInput(input: ClaudeUpstreamInput): ClaudeUpstreamSecret {
  switch (input.kind) {
    case "anthropic_api_key":
      return { kind: "anthropic_api_key", apiKey: input.apiKey };
    case "anthropic_oauth":
      return { kind: "anthropic_oauth", token: input.token };
    case "bedrock":
      return {
        kind: "bedrock",
        accessKeyId: input.accessKeyId,
        secretAccessKey: input.secretAccessKey,
        ...(input.sessionToken ? { sessionToken: input.sessionToken } : {}),
      };
  }
}

function configFromInput(input: ClaudeUpstreamInput): Record<string, unknown> {
  if (input.kind !== "bedrock") return {};
  return {
    region: input.region,
    ...(input.modelIds ? { modelIds: { ...input.modelIds } } : {}),
  };
}

function parseConfig(value: unknown): ClaudeUpstreamConfig {
  if (!isRecord(value)) return {};
  const region = trimmed(value.region);
  const modelIds = parseModelIds(value.modelIds) ?? {};
  return {
    ...(region && AWS_REGION.test(region) ? { region } : {}),
    ...(Object.keys(modelIds).length > 0 ? { modelIds } : {}),
  };
}

function parseSecret(value: unknown, kind: ClaudeUpstreamKind): ClaudeUpstreamSecret | null {
  if (!isRecord(value) || value.kind !== kind) return null;
  switch (kind) {
    case "anthropic_api_key":
      return nonEmpty(value.apiKey) ? { kind, apiKey: value.apiKey } : null;
    case "anthropic_oauth":
      return nonEmpty(value.token) ? { kind, token: value.token } : null;
    case "bedrock":
      if (!nonEmpty(value.accessKeyId) || !nonEmpty(value.secretAccessKey)) return null;
      if (value.sessionToken !== undefined && !nonEmpty(value.sessionToken)) return null;
      return {
        kind,
        accessKeyId: value.accessKeyId,
        secretAccessKey: value.secretAccessKey,
        ...(value.sessionToken ? { sessionToken: value.sessionToken } : {}),
      };
  }
}

type AadIdentity = {
  readonly id: string;
  readonly teamId: string;
  readonly kind: string;
  readonly aadVersion: 1 | 2;
};

/**
 * Version 1 is the single-upstream binding (team, kind) that migrated rows
 * still carry; version 2 adds the account id so two accounts of the same
 * kind on one team cannot be swapped.
 */
function accountAad(input: AadIdentity): Buffer {
  return input.aadVersion === 1
    ? Buffer.from(JSON.stringify(["coderouter-claude-upstream", 1, input.teamId, input.kind]), "utf8")
    : Buffer.from(JSON.stringify(["coderouter-claude-account", 2, input.teamId, input.id, input.kind]), "utf8");
}

function accountEncryptionContext(input: AadIdentity): Readonly<Record<string, string>> {
  return input.aadVersion === 1
    ? { service: "coderouter", version: "1", scope: "claude-upstream", team: input.teamId, kind: input.kind }
    : {
      service: "coderouter",
      version: "2",
      scope: "claude-account",
      team: input.teamId,
      account: input.id,
      kind: input.kind,
    };
}

function trimmed(value: unknown): string | null {
  return typeof value === "string" ? value.trim() : null;
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (!signal?.aborted) return;
  throw signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

const drizzleStore: ClaudeAccountStore = {
  async list(teamId, signal) {
    const rows = await runWithCloudDbQuerySignal(signal, () => cloudDb()
      .select()
      .from(coderouterClaudeAccounts)
      .where(eq(coderouterClaudeAccounts.teamId, teamId))
      .orderBy(asc(coderouterClaudeAccounts.createdAt), asc(coderouterClaudeAccounts.id)));
    return rows.map(rowFromDb);
  },
  async insert(row) {
    const now = new Date();
    const [written] = await cloudDb()
      .insert(coderouterClaudeAccounts)
      .values({ ...row, createdAt: now, updatedAt: now })
      .returning();
    if (!written) throw new Error("coderouter claude account insert returned no row");
    return rowFromDb(written);
  },
  async update(teamId, accountId, patch) {
    const [written] = await cloudDb()
      .update(coderouterClaudeAccounts)
      .set({
        ...(patch.label !== undefined ? { label: patch.label } : {}),
        ...(patch.state !== undefined ? { state: patch.state } : {}),
        ...(patch.identifier !== undefined ? { identifier: patch.identifier } : {}),
        updatedAt: new Date(),
      })
      .where(and(eq(coderouterClaudeAccounts.teamId, teamId), eq(coderouterClaudeAccounts.id, accountId)))
      .returning();
    return written ? rowFromDb(written) : null;
  },
  async remove(teamId, accountId) {
    const deleted = await cloudDb()
      .delete(coderouterClaudeAccounts)
      .where(and(eq(coderouterClaudeAccounts.teamId, teamId), eq(coderouterClaudeAccounts.id, accountId)))
      .returning({ id: coderouterClaudeAccounts.id });
    return deleted.length > 0;
  },
  async removeAll(teamId) {
    const deleted = await cloudDb()
      .delete(coderouterClaudeAccounts)
      .where(eq(coderouterClaudeAccounts.teamId, teamId))
      .returning({ id: coderouterClaudeAccounts.id });
    return deleted.length;
  },
  async markCooldown(accountId, until, failureCode, signal) {
    await runWithCloudDbQuerySignal(signal, () => cloudDb()
      .update(coderouterClaudeAccounts)
      .set({ cooldownUntil: until, lastFailureCode: failureCode, updatedAt: new Date() })
      .where(eq(coderouterClaudeAccounts.id, accountId)));
  },
  async touchUsed(accountId, at, signal) {
    await runWithCloudDbQuerySignal(signal, () => cloudDb()
      .update(coderouterClaudeAccounts)
      .set({ lastUsedAt: at })
      .where(eq(coderouterClaudeAccounts.id, accountId)));
  },
};

function rowFromDb(row: typeof coderouterClaudeAccounts.$inferSelect): ClaudeAccountRow {
  if (row.algorithm !== "aes-256-gcm") {
    throw new Error("unsupported coderouter claude account encryption algorithm");
  }
  if (row.aadVersion !== 1 && row.aadVersion !== 2) {
    throw new Error("unsupported coderouter claude account aad version");
  }
  return {
    id: row.id,
    teamId: row.teamId,
    kind: row.kind,
    label: row.label,
    identifier: row.identifier,
    state: row.state,
    cooldownUntil: row.cooldownUntil,
    lastUsedAt: row.lastUsedAt,
    lastFailureCode: row.lastFailureCode,
    aadVersion: row.aadVersion,
    algorithm: row.algorithm,
    ciphertext: row.ciphertext,
    nonce: row.nonce,
    authTag: row.authTag,
    encryptedDataKey: row.encryptedDataKey,
    kmsKeyId: row.kmsKeyId,
    config: row.config,
    createdBy: row.createdBy,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

const defaultService = createClaudeUpstreamService({ store: drizzleStore });

export const listClaudeAccounts = defaultService.list;
export const addClaudeAccount = defaultService.add;
export const updateClaudeAccount = defaultService.update;
export const removeClaudeAccount = defaultService.remove;
export const removeAllClaudeAccounts = defaultService.removeAll;
/** Data-plane selection; the result carries a decrypted secret. Never serialize it. */
export const selectClaudeUpstream = defaultService.select;
export const markClaudeAccountCooldown = defaultService.cooldown;
export const touchClaudeAccountUsed = defaultService.touchUsed;

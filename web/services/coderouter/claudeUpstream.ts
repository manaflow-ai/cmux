// Per-team Claude upstream for the coderouter `/v1/messages` leg.
//
// Exactly one row per team, no fallback: a team either forwards Claude
// traffic to the upstream stored here or gets a 503 telling it to configure
// one. Secrets are KMS envelope-encrypted with the same scheme as
// `coderouter_credentials`; the AAD and KMS encryption context bind the
// ciphertext to (team, kind) so a row cannot be replayed for another team.
import { eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { coderouterClaudeUpstreams } from "../../db/schema";
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

export type ClaudeUpstream = {
  readonly teamId: string;
  readonly kind: ClaudeUpstreamKind;
  readonly secret: ClaudeUpstreamSecret;
  readonly config: ClaudeUpstreamConfig;
  readonly updatedAt: Date;
};

/** What the dashboard and the GET route see. Never carries a secret. */
export type ClaudeUpstreamDescription = {
  readonly kind: ClaudeUpstreamKind;
  readonly identifier: string;
  readonly region: string | null;
  readonly modelIds: Readonly<Record<string, string>>;
  readonly updatedAt: string;
};

export type ClaudeUpstreamInput =
  | { readonly kind: "anthropic_api_key"; readonly apiKey: string }
  | { readonly kind: "anthropic_oauth"; readonly token: string }
  | {
    readonly kind: "bedrock";
    readonly region: string;
    readonly accessKeyId: string;
    readonly secretAccessKey: string;
    readonly sessionToken?: string;
    readonly modelIds?: Readonly<Record<string, string>>;
  };

export type ClaudeUpstreamRow = {
  readonly teamId: string;
  readonly kind: ClaudeUpstreamKind;
  readonly config: Record<string, unknown>;
  readonly updatedBy: string;
  readonly updatedAt: Date;
} & SecretEnvelope;

export type ClaudeUpstreamStore = {
  read(teamId: string): Promise<ClaudeUpstreamRow | null>;
  write(row: Omit<ClaudeUpstreamRow, "updatedAt">): Promise<ClaudeUpstreamRow>;
  remove(teamId: string): Promise<boolean>;
};

export type ClaudeUpstreamDependencies = {
  readonly store: ClaudeUpstreamStore;
  readonly keys?: CredentialKeyService;
  readonly keyId?: string;
};

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

export function parseClaudeUpstreamInput(value: unknown): ClaudeUpstreamInput | null {
  if (!isRecord(value)) return null;
  switch (value.kind) {
    case "anthropic_api_key": {
      const apiKey = trimmed(value.apiKey);
      return apiKey && ANTHROPIC_API_KEY.test(apiKey)
        ? { kind: "anthropic_api_key", apiKey }
        : null;
    }
    case "anthropic_oauth": {
      const token = trimmed(value.token);
      return token && ANTHROPIC_OAUTH_TOKEN.test(token)
        ? { kind: "anthropic_oauth", token }
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
      return {
        kind: "bedrock",
        region,
        accessKeyId,
        secretAccessKey,
        ...(sessionToken ? { sessionToken } : {}),
        ...(Object.keys(modelIds).length > 0 ? { modelIds } : {}),
      };
    }
    default:
      return null;
  }
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

  async function get(teamId: string): Promise<ClaudeUpstream | null> {
    const row = await store.read(teamId);
    if (!row) return null;
    const value = await decryptSecretEnvelope(row, {
      aad: upstreamAad(row),
      encryptionContext: upstreamEncryptionContext(row),
      keys: dependencies.keys,
    });
    const secret = parseSecret(value, row.kind);
    if (!secret) throw new Error("decrypted coderouter claude upstream is invalid");
    return {
      teamId: row.teamId,
      kind: row.kind,
      secret,
      config: parseConfig(row.config),
      updatedAt: row.updatedAt,
    };
  }

  async function put(
    teamId: string,
    stackUserId: string,
    input: ClaudeUpstreamInput,
  ): Promise<ClaudeUpstreamDescription> {
    if (!teamId || !stackUserId) throw new Error("invalid coderouter claude upstream owner");
    const secret = secretFromInput(input);
    const config = configFromInput(input);
    const identity = { teamId, kind: input.kind };
    const envelope = await encryptSecretEnvelope({
      aad: upstreamAad(identity),
      encryptionContext: upstreamEncryptionContext(identity),
      secret,
      keyId: dependencies.keyId,
      keys: dependencies.keys,
    });
    const row = await store.write({
      teamId,
      kind: input.kind,
      config,
      updatedBy: stackUserId,
      ...envelope,
    });
    return describeRow(row, secret);
  }

  async function remove(teamId: string): Promise<{ removed: boolean }> {
    return { removed: await store.remove(teamId) };
  }

  async function describe(teamId: string): Promise<ClaudeUpstreamDescription | null> {
    const upstream = await get(teamId);
    if (!upstream) return null;
    return {
      kind: upstream.kind,
      identifier: maskedIdentifier(upstream.secret),
      region: upstream.config.region ?? null,
      modelIds: upstream.config.modelIds ?? {},
      updatedAt: upstream.updatedAt.toISOString(),
    };
  }

  return { get, put, remove, describe };
}

function describeRow(row: ClaudeUpstreamRow, secret: ClaudeUpstreamSecret): ClaudeUpstreamDescription {
  const config = parseConfig(row.config);
  return {
    kind: row.kind,
    identifier: maskedIdentifier(secret),
    region: config.region ?? null,
    modelIds: config.modelIds ?? {},
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

function upstreamAad(input: { readonly teamId: string; readonly kind: string }): Buffer {
  return Buffer.from(
    JSON.stringify(["coderouter-claude-upstream", 1, input.teamId, input.kind]),
    "utf8",
  );
}

function upstreamEncryptionContext(
  input: { readonly teamId: string; readonly kind: string },
): Readonly<Record<string, string>> {
  return {
    service: "coderouter",
    version: "1",
    scope: "claude-upstream",
    team: input.teamId,
    kind: input.kind,
  };
}

function trimmed(value: unknown): string | null {
  return typeof value === "string" ? value.trim() : null;
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

const drizzleStore: ClaudeUpstreamStore = {
  async read(teamId) {
    const [row] = await cloudDb()
      .select()
      .from(coderouterClaudeUpstreams)
      .where(eq(coderouterClaudeUpstreams.teamId, teamId))
      .limit(1);
    return row ? rowFromDb(row) : null;
  },
  async write(row) {
    const now = new Date();
    const [written] = await cloudDb()
      .insert(coderouterClaudeUpstreams)
      .values({ ...row, createdAt: now, updatedAt: now })
      .onConflictDoUpdate({
        target: coderouterClaudeUpstreams.teamId,
        set: {
          kind: row.kind,
          algorithm: row.algorithm,
          ciphertext: row.ciphertext,
          nonce: row.nonce,
          authTag: row.authTag,
          encryptedDataKey: row.encryptedDataKey,
          kmsKeyId: row.kmsKeyId,
          config: row.config,
          updatedBy: row.updatedBy,
          updatedAt: now,
        },
      })
      .returning();
    if (!written) throw new Error("coderouter claude upstream upsert returned no row");
    return rowFromDb(written);
  },
  async remove(teamId) {
    const deleted = await cloudDb()
      .delete(coderouterClaudeUpstreams)
      .where(eq(coderouterClaudeUpstreams.teamId, teamId))
      .returning({ teamId: coderouterClaudeUpstreams.teamId });
    return deleted.length > 0;
  },
};

function rowFromDb(row: typeof coderouterClaudeUpstreams.$inferSelect): ClaudeUpstreamRow {
  if (row.algorithm !== "aes-256-gcm") {
    throw new Error("unsupported coderouter claude upstream encryption algorithm");
  }
  return {
    teamId: row.teamId,
    kind: row.kind,
    algorithm: row.algorithm,
    ciphertext: row.ciphertext,
    nonce: row.nonce,
    authTag: row.authTag,
    encryptedDataKey: row.encryptedDataKey,
    kmsKeyId: row.kmsKeyId,
    config: row.config,
    updatedBy: row.updatedBy,
    updatedAt: row.updatedAt,
  };
}

const defaultService = createClaudeUpstreamService({ store: drizzleStore });

/** Decrypted upstream for the data plane. Server-only; never serialize it. */
export const getClaudeUpstream = defaultService.get;
export const putClaudeUpstream = defaultService.put;
export const deleteClaudeUpstream = defaultService.remove;
export const describeClaudeUpstream = defaultService.describe;

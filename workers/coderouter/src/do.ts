import { DurableObject } from "cloudflare:workers";
import { managedAcquireFailure } from "./acquirePolicy";
import { allowedClassesForEndpoint } from "./families";
import { applyLimitHeaders, mergeReportedLimitState } from "./limits";
import { refreshOAuthChain, tokenExpiresSoon, type OAuthChain } from "./oauthRefresh";
import { priceUsageMicros } from "./pricing";
import { decryptEnvelopeSecret } from "./secrets";
import { selectCredential, summarizeWindows, type SelectCandidate } from "./select";
import { buildUsageIngest, subtractFlushedEstimateMicros, type StatusUpdateRow, type UsageBufferRow } from "./usageFlush";
import { nextUsagePollAt, normalizeUsagePoll, shouldPollCredential, zeroHeadroomUsageWindows } from "./usagePoll";
import type {
  AcquireRequest,
  AcquireResult,
  CredentialClass,
  CredentialLimitState,
  Family,
  PoolConfig,
  ReportRequest,
  SeedOauth,
  UsageIngest,
} from "./types";

export interface Env {
  POOL: DurableObjectNamespace<PoolCoordinator>;
  CONTROL_PLANE_BASE_URL: string;
  CODEROUTER_KEY_SIGNING_SECRET: string;
  CODEROUTER_INTERNAL_TOKEN: string;
  CODEROUTER_MASTER_KEY?: string;
  MANAGED_ANTHROPIC_API_KEY?: string;
  MANAGED_OPENAI_API_KEY?: string;
}

type SqlRow = Record<string, unknown>;
type SqlCursor = { toArray(): SqlRow[]; one<T = SqlRow>(): T | null };
type SqlStorage = { exec(query: string, ...bindings: unknown[]): SqlCursor };

interface CredentialRow {
  id: string;
  kind: string;
  class: CredentialClass;
  status: string;
  provider_account_id: string | null;
  encrypted_secret: string | null;
}

const META_CONFIG_VERSION = "configVersion";
const META_POOL_ID = "poolId";
const META_TEAM_ID = "teamId";
const META_FAMILY = "family";
const META_MANAGED_ENABLED = "managedEnabled";
const META_BALANCE_MICROS = "balanceMicros";
const META_UNFLUSHED_MICROS = "unflushedEstimateMicros";
const META_LAST_TRAFFIC_AT = "lastTrafficAt";
const FLUSH_BATCH_SIZE = 500;

export class PoolCoordinator extends DurableObject<Env> {
  private initialized: Promise<void> | null = null;
  private refreshFlights = new Map<string, Promise<OAuthChain | null>>();

  async syncConfig(config: PoolConfig): Promise<{ ok: true; ignored?: boolean }> {
    await this.init();
    const currentVersion = this.numberMeta(META_CONFIG_VERSION) ?? 0;
    if (config.configVersion < currentVersion) {
      await this.armOauthPollIfNeeded();
      return { ok: true, ignored: true };
    }
    this.writeConfig(config);
    await this.armOauthPollIfNeeded();
    return { ok: true };
  }

  async seedOauth(seed: SeedOauth): Promise<{ ok: true }> {
    await this.init();
    this.sql.exec(
      `INSERT OR REPLACE INTO oauth_chains
       (credential_id, provider, access_token, refresh_token, id_token, account_id, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      seed.credentialId,
      seed.provider,
      seed.accessToken,
      seed.refreshToken,
      seed.idToken ?? null,
      seed.accountId ?? null,
      seed.expiresAt ?? null,
    );
    await this.ctx.storage.sync();
    await this.armOauthPollIfNeeded();
    return { ok: true };
  }

  async acquire(request: AcquireRequest): Promise<AcquireResult> {
    await this.init();
    const configAvailable = await this.ensureConfig(request);
    if (!configAvailable) return { ok: false, error: "config_unavailable" };
    this.putMeta(META_LAST_TRAFFIC_AT, String(Date.now()));

    const key = this.sql.exec("SELECT kid, revoked, policy FROM keys WHERE kid = ?", request.kid).one<SqlRow>();
    if (!key || Number(key.revoked) === 1) return { ok: false, error: "key_revoked" };
    const policy = parseJsonRecord(key.policy);
    const policyAllowed = Array.isArray(policy.allowedClasses)
      ? new Set(policy.allowedClasses.filter((value): value is CredentialClass => isCredentialClass(value)))
      : null;
    const endpointAllowed = new Set(allowedClassesForEndpoint(request.endpointClass));
    const excluded = new Set(request.excludeCredentialIds ?? []);
    const allowed = (credential: CredentialRow) =>
      credential.status === "active" &&
      endpointAllowed.has(credential.class) &&
      !excluded.has(credential.id) &&
      (!policyAllowed || policyAllowed.has(credential.class)) &&
      (credential.class !== "managed" || this.booleanMeta(META_MANAGED_ENABLED));

    const credentials = this.listCredentials();
    const eligible = credentials.filter(allowed);
    if (eligible.length === 0) return { ok: false, error: "no_credentials" };

    const sticky = this.assignment(request.conversationKey);
    if (sticky) {
      const credential = eligible.find((row) => row.id === sticky);
      if (credential && this.credentialHealthy(credential.id)) {
        const managedError = this.managedFailure(credential, request);
        if (managedError) return managedError;
        this.touchAssignment(request.conversationKey, credential.id);
        return await this.buildAcquireSuccess(credential, request);
      }
    }

    const candidates: SelectCandidate[] = eligible.map((credential) => ({
      id: credential.id,
      class: credential.class,
      assignmentCount: this.assignmentCount(credential.id),
      limitState: this.limitState(credential.id),
    }));
    const selected = selectCredential(candidates, Date.now());
    if (!selected) {
      return { ok: false, error: "all_exhausted", soonestResetSeconds: soonestReset(candidates) };
    }
    const credential = eligible.find((row) => row.id === selected.id);
    if (!credential) return { ok: false, error: "no_credentials" };
    const managedError = this.managedFailure(credential, request);
    if (managedError) return managedError;
    this.touchAssignment(request.conversationKey, credential.id);
    return await this.buildAcquireSuccess(credential, request);
  }

  async report(report: ReportRequest): Promise<{ ok: true }> {
    await this.init();
    const now = Date.now();
    this.putMeta(META_LAST_TRAFFIC_AT, String(now));
    const credential = this.credential(report.credentialId);
    const previous = this.limitState(report.credentialId);
    const update = applyLimitHeaders({
      family: this.family(),
      endpointClass: report.endpointClass,
      credentialClass: credential?.class ?? "byok",
      status: report.status,
      headers: report.rateLimitHeaders,
      now,
      previousConsecutive429: previous.consecutive429,
      previousConsecutive401: previous.consecutive401,
    });
    this.writeLimitState(report.credentialId, mergeReportedLimitState(previous, update));
    if (update.needsReauth) {
      this.markCredentialStatus(report.credentialId, "needs_reauth");
    }

    const eventId = crypto.randomUUID();
    const costMicros = credential?.class === "managed" ? priceUsageMicros(report.model, report.usage) : null;
    this.sql.exec(
      `INSERT INTO usage_buffer
       (event_id, key_id, credential_id, family, endpoint_class, model, credential_class, status,
        input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated, cost_micros, latency_ms, ts)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      eventId,
      report.kid,
      report.credentialId,
      this.family(),
      report.endpointClass,
      report.model ?? null,
      credential?.class ?? "byok",
      report.status,
      report.usage.inputTokens,
      report.usage.outputTokens,
      report.usage.cacheReadTokens,
      report.usage.cacheWriteTokens,
      report.usage.estimated ? 1 : 0,
      costMicros,
      report.latencyMs,
      now,
    );
    if (credential?.class === "managed" && costMicros !== null) {
      this.putMeta(META_UNFLUSHED_MICROS, String((this.numberMeta(META_UNFLUSHED_MICROS) ?? 0) + costMicros));
    }
    await this.setAlarmIfSooner(now + 10_000);
    return { ok: true };
  }

  async alarm(): Promise<void> {
    await this.init();
    await this.flushUsage();
    await this.pollUsage();
    this.pruneAssignments();
    if (this.hasPendingUsage() || this.hasPendingStatusUpdates() || this.hasActiveOauth()) {
      await this.ctx.storage.setAlarm(this.nextAlarmTimestamp());
    }
  }

  private async buildAcquireSuccess(credential: CredentialRow, request: AcquireRequest): Promise<AcquireResult> {
    let secret: string | null = null;
    let accountId: string | undefined;
    if (credential.class === "managed") {
      secret = this.managedSecret(request.family);
    } else if (credential.class === "byok") {
      secret = credential.encrypted_secret
        ? await decryptEnvelopeSecret(credential.encrypted_secret, this.env.CODEROUTER_MASTER_KEY)
        : null;
    } else {
      const chain = await this.accessChain(credential.id);
      if (!chain) return { ok: false, error: "no_credentials" };
      secret = chain.accessToken;
      accountId = chain.accountId;
    }
    if (!secret) return { ok: false, error: "no_credentials" };
    const baseAuth: Record<string, string> =
      request.endpointClass === "anthropic" && credential.class !== "oauth"
        ? { "x-api-key": secret }
        : { authorization: `Bearer ${secret}` };
    const authHeaders: Record<string, string> = { ...baseAuth };
    if (request.endpointClass === "codex" && accountId) authHeaders["chatgpt-account-id"] = accountId;
    return {
      ok: true,
      credentialId: credential.id,
      class: credential.class,
      authHeaders,
      upstreamBase: request.endpointClass === "anthropic" ? "https://api.anthropic.com" : request.endpointClass === "codex" ? "https://chatgpt.com" : "https://api.openai.com",
      accountId,
    };
  }

  private async accessChain(credentialId: string): Promise<OAuthChain | null> {
    const chain = this.oauthChain(credentialId);
    if (!chain) return null;
    const provider = this.family();
    if (!tokenExpiresSoon(provider, chain)) return chain;
    const existing = this.refreshFlights.get(credentialId);
    if (existing) return existing;
    const flight = this.refreshChain(credentialId, provider, chain).finally(() => this.refreshFlights.delete(credentialId));
    this.refreshFlights.set(credentialId, flight);
    return flight;
  }

  private async refreshChain(credentialId: string, provider: Family, chain: OAuthChain): Promise<OAuthChain | null> {
    const refreshed = await refreshOAuthChain(provider, chain);
    if (!refreshed.ok) {
      if (refreshed.failure.refreshTokenFailure) {
        this.markCredentialStatus(credentialId, "needs_reauth");
        await this.setAlarmIfSooner(Date.now() + 10_000);
      }
      return null;
    }
    this.sql.exec(
      `UPDATE oauth_chains SET access_token = ?, refresh_token = ?, id_token = ?, account_id = ?, expires_at = ?
       WHERE credential_id = ?`,
      refreshed.chain.accessToken,
      refreshed.chain.refreshToken,
      refreshed.chain.idToken ?? null,
      refreshed.chain.accountId ?? null,
      refreshed.chain.expiresAt ?? null,
      credentialId,
    );
    await this.ctx.storage.sync();
    return refreshed.chain;
  }

  private async flushUsage(): Promise<void> {
    const poolId = this.stringMeta(META_POOL_ID);
    if (!poolId || !this.env.CONTROL_PLANE_BASE_URL || !this.env.CODEROUTER_INTERNAL_TOKEN) return;
    const rows = this.sql.exec("SELECT * FROM usage_buffer ORDER BY ts LIMIT ?", FLUSH_BATCH_SIZE).toArray() as unknown as UsageBufferRow[];
    const statusRows = this.sql.exec("SELECT * FROM status_updates").toArray() as unknown as StatusUpdateRow[];
    if (rows.length === 0 && statusRows.length === 0) return;
    const { body, flushedEstimateMicros } = buildUsageIngest(poolId, rows, statusRows);
    const response = await fetch(`${this.env.CONTROL_PLANE_BASE_URL}/api/coderouter/internal/usage-ingest`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${this.env.CODEROUTER_INTERNAL_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      await this.ctx.storage.setAlarm(Date.now() + 60_000);
      return;
    }
    const payload = (await response.json().catch(() => null)) as { balanceMicros?: unknown } | null;
    const ids = rows.map((row) => String(row.event_id));
    for (const id of ids) this.sql.exec("DELETE FROM usage_buffer WHERE event_id = ?", id);
    for (const row of statusRows) this.sql.exec("DELETE FROM status_updates WHERE credential_id = ?", String(row.credential_id));
    if (typeof payload?.balanceMicros === "number") this.putMeta(META_BALANCE_MICROS, String(payload.balanceMicros));
    this.putMeta(
      META_UNFLUSHED_MICROS,
      String(subtractFlushedEstimateMicros(this.numberMeta(META_UNFLUSHED_MICROS) ?? 0, flushedEstimateMicros)),
    );
  }

  private async pollUsage(): Promise<void> {
    const lastTrafficAt = this.numberMeta(META_LAST_TRAFFIC_AT) ?? 0;
    const now = Date.now();
    const oauthRows = this.sql.exec("SELECT id FROM credentials WHERE class = 'oauth' AND status = 'active'").toArray();
    for (const row of oauthRows) {
      const credentialId = String(row.id);
      const currentState = this.limitState(credentialId);
      if (!shouldPollCredential({ now, lastTrafficAt, lastPolledAt: currentState.lastPolledAt })) continue;
      const chain = await this.accessChain(credentialId);
      if (!chain) continue;
      const provider = this.family();
      const url =
        provider === "anthropic"
          ? "https://api.anthropic.com/api/oauth/usage"
          : "https://chatgpt.com/backend-api/wham/usage";
      const headers = new Headers({ authorization: `Bearer ${chain.accessToken}` });
      if (provider === "anthropic") headers.set("anthropic-beta", "oauth-2025-04-20");
      if (provider === "openai" && chain.accountId) headers.set("ChatGPT-Account-ID", chain.accountId);
      const response = await fetch(url, { headers });
      if (response.status === 401 || response.status === 403) {
        this.writeLimitState(credentialId, {
          ...this.limitState(credentialId),
          windows: zeroHeadroomUsageWindows(provider),
          lastPolledAt: now,
        });
        continue;
      }
      if (!response.ok) {
        this.writeLimitState(credentialId, { ...this.limitState(credentialId), lastPolledAt: now });
        continue;
      }
      const payload = await response.json().catch(() => null);
      const windows = normalizeUsagePoll(provider, payload, now);
      this.writeLimitState(credentialId, {
        ...this.limitState(credentialId),
        ...(windows.length > 0 ? { windows } : {}),
        lastPolledAt: now,
      });
    }
  }

  private pruneAssignments(): void {
    this.sql.exec("DELETE FROM assignments WHERE last_used_at < ?", Date.now() - 7 * 24 * 60 * 60 * 1000);
  }

  private async ensureConfig(request: AcquireRequest): Promise<boolean> {
    if (this.stringMeta(META_CONFIG_VERSION)) return true;
    const poolId = `${this.teamIdFromRequest(request)}:${request.family}`;
    if (!this.env.CONTROL_PLANE_BASE_URL || !this.env.CODEROUTER_INTERNAL_TOKEN) return false;
    const url = new URL(`${this.env.CONTROL_PLANE_BASE_URL}/api/coderouter/internal/pool-config`);
    url.searchParams.set("poolId", poolId);
    const response = await fetch(url, { headers: { authorization: `Bearer ${this.env.CODEROUTER_INTERNAL_TOKEN}` } }).catch(() => null);
    if (!response?.ok) return false;
    const config = await response.json().catch(() => null);
    if (!config || typeof config !== "object" || Array.isArray(config)) return false;
    this.writeConfig(config as PoolConfig);
    return true;
  }

  private teamIdFromRequest(request: AcquireRequest): string {
    const existing = this.stringMeta(META_TEAM_ID);
    if (existing) return existing;
    return request.teamId ?? "";
  }

  private writeConfig(config: PoolConfig): void {
    this.putMeta(META_POOL_ID, config.poolId);
    this.putMeta(META_TEAM_ID, config.teamId);
    this.putMeta(META_FAMILY, config.family);
    this.putMeta(META_CONFIG_VERSION, String(config.configVersion));
    this.putMeta(META_MANAGED_ENABLED, config.managed.enabled ? "1" : "0");
    this.putMeta(META_BALANCE_MICROS, String(config.balanceMicros));
    this.sql.exec("DELETE FROM keys");
    for (const key of config.keys) {
      this.sql.exec("INSERT INTO keys (kid, revoked, policy) VALUES (?, ?, ?)", key.kid, key.revoked ? 1 : 0, JSON.stringify(key.policy));
    }
    this.sql.exec("DELETE FROM credentials");
    for (const credential of config.credentials) {
      this.sql.exec(
        `INSERT INTO credentials (id, kind, class, status, label, provider_account_id, encrypted_secret)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        credential.id,
        credential.kind,
        credential.class,
        credential.status,
        credential.label ?? null,
        credential.providerAccountId ?? null,
        credential.encryptedSecret ?? null,
      );
    }
  }

  private async init(): Promise<void> {
    this.initialized ??= Promise.resolve().then(() => {
      this.sql.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
      this.sql.exec("CREATE TABLE IF NOT EXISTS keys (kid TEXT PRIMARY KEY, revoked INTEGER NOT NULL, policy TEXT NOT NULL)");
      this.sql.exec(
        `CREATE TABLE IF NOT EXISTS credentials (
          id TEXT PRIMARY KEY, kind TEXT NOT NULL, class TEXT NOT NULL, status TEXT NOT NULL,
          label TEXT, provider_account_id TEXT, encrypted_secret TEXT
        )`,
      );
      this.sql.exec(
        `CREATE TABLE IF NOT EXISTS oauth_chains (
          credential_id TEXT PRIMARY KEY, provider TEXT NOT NULL, access_token TEXT NOT NULL,
          refresh_token TEXT NOT NULL, id_token TEXT, account_id TEXT, expires_at INTEGER
        )`,
      );
      this.sql.exec(
        "CREATE TABLE IF NOT EXISTS assignments (conversation_key TEXT PRIMARY KEY, credential_id TEXT NOT NULL, last_used_at INTEGER NOT NULL)",
      );
      this.sql.exec("CREATE INDEX IF NOT EXISTS assignments_credential_idx ON assignments (credential_id)");
      this.sql.exec("CREATE TABLE IF NOT EXISTS limit_state (credential_id TEXT PRIMARY KEY, state TEXT NOT NULL)");
      this.sql.exec("CREATE TABLE IF NOT EXISTS status_updates (credential_id TEXT PRIMARY KEY, status TEXT NOT NULL)");
      this.sql.exec(
        `CREATE TABLE IF NOT EXISTS usage_buffer (
          event_id TEXT PRIMARY KEY, key_id TEXT, credential_id TEXT, family TEXT NOT NULL,
          endpoint_class TEXT NOT NULL, model TEXT, credential_class TEXT NOT NULL, status INTEGER NOT NULL,
          input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL,
          cache_write_tokens INTEGER NOT NULL, estimated INTEGER NOT NULL, cost_micros INTEGER, latency_ms INTEGER, ts INTEGER NOT NULL
        )`,
      );
    });
    await this.initialized;
  }

  private get sql(): SqlStorage {
    return (this.ctx.storage as unknown as { sql: SqlStorage }).sql;
  }

  private credential(id: string): CredentialRow | null {
    return (this.sql.exec("SELECT * FROM credentials WHERE id = ?", id).one<CredentialRow>() as CredentialRow | null) ?? null;
  }

  private listCredentials(): CredentialRow[] {
    return this.sql.exec("SELECT * FROM credentials").toArray() as unknown as CredentialRow[];
  }

  private assignment(conversationKey: string): string | null {
    const row = this.sql.exec("SELECT credential_id FROM assignments WHERE conversation_key = ?", conversationKey).one<SqlRow>();
    return nullableString(row?.credential_id);
  }

  private assignmentCount(credentialId: string): number {
    const row = this.sql.exec("SELECT COUNT(*) as count FROM assignments WHERE credential_id = ?", credentialId).one<SqlRow>();
    return Number(row?.count ?? 0);
  }

  private credentialHealthy(credentialId: string): boolean {
    const state = this.limitState(credentialId);
    const summary = summarizeWindows(state.windows, Date.now(), state.cooldownUntil);
    return !summary.exhausted && !state.needsReauth;
  }

  private limitState(credentialId: string): CredentialLimitState {
    const row = this.sql.exec("SELECT state FROM limit_state WHERE credential_id = ?", credentialId).one<SqlRow>();
    const parsed = parseJsonRecord(row?.state);
    return {
      windows: Array.isArray(parsed.windows) ? (parsed.windows as CredentialLimitState["windows"]) : [],
      cooldownUntil: typeof parsed.cooldownUntil === "number" ? parsed.cooldownUntil : undefined,
      consecutive429: typeof parsed.consecutive429 === "number" ? parsed.consecutive429 : 0,
      consecutive401: typeof parsed.consecutive401 === "number" ? parsed.consecutive401 : 0,
      needsReauth: parsed.needsReauth === true,
      lastPolledAt: typeof parsed.lastPolledAt === "number" ? parsed.lastPolledAt : undefined,
    };
  }

  private writeLimitState(credentialId: string, state: CredentialLimitState): void {
    this.sql.exec("INSERT OR REPLACE INTO limit_state (credential_id, state) VALUES (?, ?)", credentialId, JSON.stringify(state));
  }

  private oauthChain(credentialId: string): OAuthChain | null {
    const row = this.sql.exec("SELECT * FROM oauth_chains WHERE credential_id = ?", credentialId).one<SqlRow>();
    if (!row) return null;
    return {
      accessToken: String(row.access_token),
      refreshToken: String(row.refresh_token),
      idToken: nullableString(row.id_token) ?? undefined,
      accountId: nullableString(row.account_id) ?? undefined,
      expiresAt: row.expires_at === null || row.expires_at === undefined ? undefined : Number(row.expires_at),
    };
  }

  private hasPendingUsage(): boolean {
    const row = this.sql.exec("SELECT COUNT(*) as count FROM usage_buffer").one<SqlRow>();
    return Number(row?.count ?? 0) > 0;
  }

  private hasPendingStatusUpdates(): boolean {
    const row = this.sql.exec("SELECT COUNT(*) as count FROM status_updates").one<SqlRow>();
    return Number(row?.count ?? 0) > 0;
  }

  private hasActiveOauth(): boolean {
    const row = this.sql.exec("SELECT COUNT(*) as count FROM credentials WHERE class = 'oauth' AND status = 'active'").one<SqlRow>();
    return Number(row?.count ?? 0) > 0;
  }

  private nextAlarmTimestamp(): number {
    const now = Date.now();
    if (this.hasPendingUsage() || this.hasPendingStatusUpdates()) return now + 60_000;
    const lastTrafficAt = this.numberMeta(META_LAST_TRAFFIC_AT) ?? 0;
    const oauthRows = this.sql.exec("SELECT id FROM credentials WHERE class = 'oauth' AND status = 'active'").toArray();
    let next: number | null = null;
    for (const row of oauthRows) {
      const credentialId = String(row.id);
      const candidate = nextUsagePollAt({
        now,
        lastTrafficAt,
        lastPolledAt: this.limitState(credentialId).lastPolledAt,
      });
      next = next === null ? candidate : Math.min(next, candidate);
    }
    return Math.max(now, next ?? now + 60_000);
  }

  private stringMeta(key: string): string | null {
    const row = this.sql.exec("SELECT value FROM meta WHERE key = ?", key).one<SqlRow>();
    return nullableString(row?.value);
  }

  private numberMeta(key: string): number | null {
    const value = this.stringMeta(key);
    if (value === null) return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }

  private booleanMeta(key: string): boolean {
    return this.stringMeta(key) === "1";
  }

  private putMeta(key: string, value: string): void {
    this.sql.exec("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", key, value);
  }

  private family(): Family {
    return this.stringMeta(META_FAMILY) === "anthropic" ? "anthropic" : "openai";
  }

  private managedSecret(family: Family): string | null {
    return family === "anthropic" ? (this.env.MANAGED_ANTHROPIC_API_KEY ?? null) : (this.env.MANAGED_OPENAI_API_KEY ?? null);
  }

  private touchAssignment(conversationKey: string, credentialId: string): void {
    this.sql.exec(
      `INSERT INTO assignments (conversation_key, credential_id, last_used_at)
       VALUES (?, ?, ?)
       ON CONFLICT(conversation_key) DO UPDATE SET credential_id = excluded.credential_id, last_used_at = excluded.last_used_at`,
      conversationKey,
      credentialId,
      Date.now(),
    );
  }

  private markCredentialStatus(credentialId: string, status: "active" | "needs_reauth"): void {
    this.sql.exec("UPDATE credentials SET status = ? WHERE id = ?", status, credentialId);
    this.sql.exec("INSERT OR REPLACE INTO status_updates (credential_id, status) VALUES (?, ?)", credentialId, status);
  }

  private async setAlarmIfSooner(timestamp: number): Promise<void> {
    const pending = await this.ctx.storage.getAlarm();
    if (pending === null || pending > timestamp) await this.ctx.storage.setAlarm(timestamp);
  }

  private async armOauthPollIfNeeded(): Promise<void> {
    if (this.hasActiveOauth()) await this.setAlarmIfSooner(Date.now() + 5000);
  }

  private managedFailure(credential: CredentialRow, request: AcquireRequest): AcquireResult | null {
    return managedAcquireFailure({
      credentialClass: credential.class,
      model: request.model,
      balanceMicros: this.numberMeta(META_BALANCE_MICROS) ?? 0,
      unflushedEstimateMicros: this.numberMeta(META_UNFLUSHED_MICROS) ?? 0,
    });
  }
}

function parseJsonRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "string") return {};
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function nullableString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function isCredentialClass(value: unknown): value is CredentialClass {
  return value === "oauth" || value === "byok" || value === "managed";
}

function soonestReset(candidates: SelectCandidate[]): number | undefined {
  let reset: number | undefined;
  const now = Date.now();
  for (const candidate of candidates) {
    const summary = summarizeWindows(candidate.limitState.windows, now, candidate.limitState.cooldownUntil);
    if (summary.soonestResetSeconds === undefined) continue;
    reset = reset === undefined ? summary.soonestResetSeconds : Math.min(reset, summary.soonestResetSeconds);
  }
  return reset;
}

/**
 * Domain, verification, TLS rule and forward-auth tables (migration 0018).
 * Every read and write is keyed by tenant, except the two ownership questions
 * the routing check must ask across tenants (who verified the most specific
 * domain covering a name, and who verified names below a wildcard), which
 * return only the domain and its tenant.
 */
import { Context, Effect, Layer, Schema } from "effect";
import { TlsRuleSpec } from "../api/domains.ts";
import { TenantId, UpstreamId } from "../lib/ids.ts";
import { DomainId, DomainVerificationId, ForwardAuthId, TlsRuleId } from "../lib/domain-ids.ts";
import { SqlClient, StoreError, type SqlClientService } from "./sql.ts";

export interface DomainRow {
  readonly id: DomainId;
  readonly tenantId: TenantId;
  readonly domain: string;
  readonly createdBy: string;
  readonly createdAt: Date;
  /** Null while the reservation waits for its challenge. */
  readonly verifiedAt: Date | null;
}

export interface VerificationRow {
  readonly id: DomainVerificationId;
  readonly tenantId: TenantId;
  readonly domain: string;
  /** The provider's challenge id. Internal only. */
  readonly upstreamId: UpstreamId;
  readonly recordName: string;
  readonly code: string;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly verifiedAt: Date | null;
}

export interface ForwardAuthFields {
  readonly url: string;
  readonly timeoutMs: number;
  readonly headerNames: ReadonlyArray<string>;
  readonly authResponseHeaders: ReadonlyArray<string>;
  readonly protectedCookies: ReadonlyArray<string>;
}

export interface ForwardAuthRow extends ForwardAuthFields {
  readonly id: ForwardAuthId;
  readonly tenantId: TenantId;
  /** The provider's configuration id. Internal only. */
  readonly upstreamId: UpstreamId;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly updatedAt: Date;
}

export interface TlsRuleFields {
  readonly domain: string;
  readonly spec: TlsRuleSpec;
  /** cmux ids of every VM the rule names. */
  readonly vmIds: ReadonlyArray<string>;
  readonly forwardAuthId: string | null;
}

export interface TlsRuleRow extends TlsRuleFields {
  readonly id: TlsRuleId;
  readonly tenantId: TenantId;
  /** The provider's rule id. Internal only. */
  readonly upstreamId: UpstreamId;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly updatedAt: Date;
}

export type DomainClaim =
  /** The domain is reserved for this tenant (newly, refreshed, or taken over from a lapsed reservation). */
  | { readonly kind: "claimed"; readonly row: DomainRow }
  /** This tenant already verified it. */
  | { readonly kind: "verified"; readonly row: DomainRow }
  /** Another tenant holds it. */
  | { readonly kind: "taken" };

export interface DomainOwner {
  readonly domain: string;
  readonly tenantId: TenantId;
}

export interface DomainStoreService {
  /** Reserves `domain` for the tenant unless another tenant verified it or holds a reservation newer than `staleBefore`. */
  readonly claimDomain: (tenant: TenantId, domain: string, candidate: DomainId, createdBy: string, at: Date, staleBefore: Date) => Effect.Effect<DomainClaim, StoreError>;
  /** Drops the tenant's pending reservation of `domain` when it has no verification left for it. */
  readonly releasePendingClaim: (tenant: TenantId, domain: string) => Effect.Effect<void, StoreError>;
  /** Marks the tenant's reservation verified; null when the reservation is no longer the tenant's. */
  readonly markDomainVerified: (tenant: TenantId, domain: string, at: Date) => Effect.Effect<DomainRow | null, StoreError>;
  readonly listDomains: (tenant: TenantId) => Effect.Effect<ReadonlyArray<DomainRow>, StoreError>;
  readonly findDomain: (tenant: TenantId, id: DomainId) => Effect.Effect<DomainRow | null, StoreError>;
  /** Releases the tenant's verified domain and its verification records. */
  readonly deleteDomain: (tenant: TenantId, id: DomainId) => Effect.Effect<boolean, StoreError>;
  /** Verified domains among `domains`, with their tenants. */
  readonly verifiedOwners: (domains: ReadonlyArray<string>) => Effect.Effect<ReadonlyArray<DomainOwner>, StoreError>;
  /** Verified domains strictly below `base`, with their tenants. */
  readonly verifiedBelow: (base: string) => Effect.Effect<ReadonlyArray<DomainOwner>, StoreError>;

  readonly insertVerification: (row: VerificationRow) => Effect.Effect<void, StoreError>;
  readonly listVerifications: (tenant: TenantId, state: "pending" | "verified" | null) => Effect.Effect<ReadonlyArray<VerificationRow>, StoreError>;
  readonly findVerification: (tenant: TenantId, id: DomainVerificationId) => Effect.Effect<VerificationRow | null, StoreError>;
  readonly markVerificationVerified: (tenant: TenantId, id: DomainVerificationId, at: Date) => Effect.Effect<void, StoreError>;
  /** Deletes a pending verification; false when it is not the tenant's or already verified. */
  readonly deletePendingVerification: (tenant: TenantId, id: DomainVerificationId) => Effect.Effect<boolean, StoreError>;
  readonly countPendingVerifications: (tenant: TenantId) => Effect.Effect<number, StoreError>;

  readonly insertForwardAuth: (row: ForwardAuthRow) => Effect.Effect<void, StoreError>;
  readonly listForwardAuths: (tenant: TenantId) => Effect.Effect<ReadonlyArray<ForwardAuthRow>, StoreError>;
  readonly findForwardAuth: (tenant: TenantId, id: ForwardAuthId) => Effect.Effect<ForwardAuthRow | null, StoreError>;
  readonly updateForwardAuth: (tenant: TenantId, id: ForwardAuthId, fields: ForwardAuthFields, at: Date) => Effect.Effect<ForwardAuthRow | null, StoreError>;
  readonly deleteForwardAuth: (tenant: TenantId, id: ForwardAuthId) => Effect.Effect<void, StoreError>;
  readonly countForwardAuths: (tenant: TenantId) => Effect.Effect<number, StoreError>;

  readonly insertTlsRule: (row: TlsRuleRow) => Effect.Effect<void, StoreError>;
  /** Newest first. */
  readonly listTlsRules: (tenant: TenantId) => Effect.Effect<ReadonlyArray<TlsRuleRow>, StoreError>;
  readonly findTlsRule: (tenant: TenantId, id: TlsRuleId) => Effect.Effect<TlsRuleRow | null, StoreError>;
  readonly updateTlsRule: (tenant: TenantId, id: TlsRuleId, fields: TlsRuleFields, at: Date) => Effect.Effect<TlsRuleRow | null, StoreError>;
  readonly deleteTlsRule: (tenant: TenantId, id: TlsRuleId) => Effect.Effect<void, StoreError>;
  readonly countTlsRules: (tenant: TenantId) => Effect.Effect<number, StoreError>;
  readonly countTlsRulesUsingForwardAuth: (tenant: TenantId, id: ForwardAuthId) => Effect.Effect<number, StoreError>;
  /** The tenant's rules on `domain`, on a name below it, or on a wildcard below it. */
  readonly countTlsRulesUnder: (tenant: TenantId, domain: string) => Effect.Effect<number, StoreError>;
}

export class DomainStore extends Context.Tag("cmux-vm/DomainStore")<DomainStore, DomainStoreService>() {}

const When = Schema.Union(Schema.DateFromSelf, Schema.Date);
const Strings = Schema.parseJson(Schema.Array(Schema.String));

const DomainSql = Schema.Struct({
  id: DomainId, tenant_id: TenantId, domain: Schema.String, created_by: Schema.String, created_at: When, verified_at: Schema.NullOr(When),
});
const VerificationSql = Schema.Struct({
  id: DomainVerificationId, tenant_id: TenantId, domain: Schema.String, upstream_verification_id: UpstreamId,
  record_name: Schema.String, verification_code: Schema.String, created_by: Schema.String, created_at: When, verified_at: Schema.NullOr(When),
});
const ForwardAuthSql = Schema.Struct({
  id: ForwardAuthId, tenant_id: TenantId, upstream_id: UpstreamId, url: Schema.String, timeout_ms: Schema.Number,
  header_names: Strings, auth_response_headers: Strings, protected_cookies: Strings,
  created_by: Schema.String, created_at: When, updated_at: When,
});
const RuleSql = Schema.Struct({
  id: TlsRuleId, tenant_id: TenantId, upstream_id: UpstreamId, domain: Schema.String, spec: Schema.parseJson(TlsRuleSpec),
  vm_ids: Strings, forward_auth_id: Schema.NullOr(Schema.String), created_by: Schema.String, created_at: When, updated_at: When,
});
const Count = Schema.Array(Schema.Struct({ count: Schema.Number }));
const Owners = Schema.Array(Schema.Struct({ domain: Schema.String, tenant_id: TenantId }));

const DOMAIN_COLUMNS = "id, tenant_id, domain, created_by, created_at, verified_at";
const VERIFICATION_COLUMNS = "id, tenant_id, domain, upstream_verification_id, record_name, verification_code, created_by, created_at, verified_at";
const FORWARD_AUTH_COLUMNS = "id, tenant_id, upstream_id, url, timeout_ms, header_names::text AS header_names, auth_response_headers::text AS auth_response_headers, protected_cookies::text AS protected_cookies, created_by, created_at, updated_at";
const RULE_COLUMNS = "id, tenant_id, upstream_id, domain, spec::text AS spec, vm_ids::text AS vm_ids, forward_auth_id, created_by, created_at, updated_at";

const decode = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: unknown) =>
  Schema.decodeUnknown(schema)(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));

const toDomain = (row: typeof DomainSql.Type): DomainRow => ({
  id: row.id, tenantId: row.tenant_id, domain: row.domain, createdBy: row.created_by, createdAt: row.created_at, verifiedAt: row.verified_at,
});
const toVerification = (row: typeof VerificationSql.Type): VerificationRow => ({
  id: row.id, tenantId: row.tenant_id, domain: row.domain, upstreamId: row.upstream_verification_id, recordName: row.record_name,
  code: row.verification_code, createdBy: row.created_by, createdAt: row.created_at, verifiedAt: row.verified_at,
});
const toForwardAuth = (row: typeof ForwardAuthSql.Type): ForwardAuthRow => ({
  id: row.id, tenantId: row.tenant_id, upstreamId: row.upstream_id, url: row.url, timeoutMs: row.timeout_ms,
  headerNames: row.header_names, authResponseHeaders: row.auth_response_headers, protectedCookies: row.protected_cookies,
  createdBy: row.created_by, createdAt: row.created_at, updatedAt: row.updated_at,
});
const toRule = (row: typeof RuleSql.Type): TlsRuleRow => ({
  id: row.id, tenantId: row.tenant_id, upstreamId: row.upstream_id, domain: row.domain, spec: row.spec, vmIds: row.vm_ids,
  forwardAuthId: row.forward_auth_id, createdBy: row.created_by, createdAt: row.created_at, updatedAt: row.updated_at,
});

const json = (value: unknown): string => JSON.stringify(value);

export const sqlDomainStore = (sql: SqlClientService): DomainStoreService => {
  const domains = (operation: string, text: string, params: ReadonlyArray<string | null>) =>
    sql.query(operation, text, params).pipe(Effect.flatMap(decode(Schema.Array(DomainSql), operation)), Effect.map((rows) => rows.map(toDomain)));
  const verifications = (operation: string, text: string, params: ReadonlyArray<string | null>) =>
    sql.query(operation, text, params).pipe(Effect.flatMap(decode(Schema.Array(VerificationSql), operation)), Effect.map((rows) => rows.map(toVerification)));
  const forwardAuths = (operation: string, text: string, params: ReadonlyArray<string | number | null>) =>
    sql.query(operation, text, params).pipe(Effect.flatMap(decode(Schema.Array(ForwardAuthSql), operation)), Effect.map((rows) => rows.map(toForwardAuth)));
  const rules = (operation: string, text: string, params: ReadonlyArray<string | null>) =>
    sql.query(operation, text, params).pipe(Effect.flatMap(decode(Schema.Array(RuleSql), operation)), Effect.map((rows) => rows.map(toRule)));
  const count = (operation: string, text: string, params: ReadonlyArray<string>) =>
    sql.query(operation, text, params).pipe(Effect.flatMap(decode(Count, operation)), Effect.map((rows) => rows[0]?.count ?? 0));
  const owners = (operation: string, text: string, params: ReadonlyArray<string>) =>
    sql.query(operation, text, params).pipe(Effect.flatMap(decode(Owners, operation)), Effect.map((rows) => rows.map((row) => ({ domain: row.domain, tenantId: row.tenant_id }))));

  return {
    claimDomain: (tenant, domain, candidate, createdBy, at, staleBefore) => Effect.gen(function* () {
      // One statement decides the reservation: a fresh insert, a refresh of the tenant's own pending row,
      // or a takeover of another tenant's lapsed pending row (which gets a new id). Verified rows never move.
      const claimed = yield* domains("domains.claim",
        `INSERT INTO cmux_vm.domains AS d (${DOMAIN_COLUMNS}) VALUES ($1, $2, $3, $4, $5, NULL)
         ON CONFLICT (domain) DO UPDATE SET
           id = CASE WHEN d.tenant_id = EXCLUDED.tenant_id THEN d.id ELSE EXCLUDED.id END,
           tenant_id = EXCLUDED.tenant_id, created_by = EXCLUDED.created_by, created_at = EXCLUDED.created_at
         WHERE d.verified_at IS NULL AND (d.tenant_id = EXCLUDED.tenant_id OR d.created_at < $6::timestamptz)
         RETURNING ${DOMAIN_COLUMNS}`,
        [candidate, tenant, domain, createdBy, at.toISOString(), staleBefore.toISOString()]);
      const row = claimed[0];
      if (row !== undefined) return { kind: "claimed", row } as const;
      const current = (yield* domains("domains.claimed", `SELECT ${DOMAIN_COLUMNS} FROM cmux_vm.domains WHERE domain = $1`, [domain]))[0];
      return current !== undefined && current.tenantId === tenant && current.verifiedAt !== null ? { kind: "verified", row: current } as const : { kind: "taken" } as const;
    }),
    releasePendingClaim: (tenant, domain) => sql.query("domains.release",
      `DELETE FROM cmux_vm.domains WHERE tenant_id = $1 AND domain = $2 AND verified_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM cmux_vm.domain_verifications v WHERE v.tenant_id = $1 AND v.domain = $2)`, [tenant, domain]).pipe(Effect.asVoid),
    markDomainVerified: (tenant, domain, at) => domains("domains.verify",
      `UPDATE cmux_vm.domains SET verified_at = COALESCE(verified_at, $3::timestamptz) WHERE tenant_id = $1 AND domain = $2 RETURNING ${DOMAIN_COLUMNS}`,
      [tenant, domain, at.toISOString()]).pipe(Effect.map((rows) => rows[0] ?? null)),
    listDomains: (tenant) => domains("domains.list",
      `SELECT ${DOMAIN_COLUMNS} FROM cmux_vm.domains WHERE tenant_id = $1 AND verified_at IS NOT NULL ORDER BY verified_at DESC, id`, [tenant]),
    findDomain: (tenant, id) => domains("domains.find",
      `SELECT ${DOMAIN_COLUMNS} FROM cmux_vm.domains WHERE tenant_id = $1 AND id = $2 AND verified_at IS NOT NULL`, [tenant, id]).pipe(Effect.map((rows) => rows[0] ?? null)),
    deleteDomain: (tenant, id) => Effect.gen(function* () {
      const removed = yield* domains("domains.delete",
        `DELETE FROM cmux_vm.domains WHERE tenant_id = $1 AND id = $2 AND verified_at IS NOT NULL RETURNING ${DOMAIN_COLUMNS}`, [tenant, id]);
      const row = removed[0];
      if (row === undefined) return false;
      yield* sql.query("domains.deleteVerifications", "DELETE FROM cmux_vm.domain_verifications WHERE tenant_id = $1 AND domain = $2", [tenant, row.domain]);
      return true;
    }),
    verifiedOwners: (names) => names.length === 0 ? Effect.succeed([]) : owners("domains.owners",
      "SELECT domain, tenant_id FROM cmux_vm.domains WHERE verified_at IS NOT NULL AND domain IN (SELECT jsonb_array_elements_text($1::text::jsonb))", [json(names)]),
    verifiedBelow: (base) => owners("domains.below",
      "SELECT domain, tenant_id FROM cmux_vm.domains WHERE verified_at IS NOT NULL AND char_length(domain) > char_length($1) + 1 AND right(domain, char_length($1) + 1) = '.' || $1", [base]),

    insertVerification: (row) => sql.query("verifications.insert",
      `INSERT INTO cmux_vm.domain_verifications (${VERIFICATION_COLUMNS}) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [row.id, row.tenantId, row.domain, row.upstreamId, row.recordName, row.code, row.createdBy, row.createdAt.toISOString(), row.verifiedAt?.toISOString() ?? null]).pipe(Effect.asVoid),
    listVerifications: (tenant, state) => verifications("verifications.list",
      `SELECT ${VERIFICATION_COLUMNS} FROM cmux_vm.domain_verifications WHERE tenant_id = $1
       AND ($2::text IS NULL OR ($2::text = 'verified') = (verified_at IS NOT NULL)) ORDER BY created_at DESC, id`, [tenant, state]),
    findVerification: (tenant, id) => verifications("verifications.find",
      `SELECT ${VERIFICATION_COLUMNS} FROM cmux_vm.domain_verifications WHERE tenant_id = $1 AND id = $2`, [tenant, id]).pipe(Effect.map((rows) => rows[0] ?? null)),
    markVerificationVerified: (tenant, id, at) => sql.query("verifications.verify",
      "UPDATE cmux_vm.domain_verifications SET verified_at = COALESCE(verified_at, $3::timestamptz) WHERE tenant_id = $1 AND id = $2", [tenant, id, at.toISOString()]).pipe(Effect.asVoid),
    deletePendingVerification: (tenant, id) => count("verifications.delete",
      "WITH removed AS (DELETE FROM cmux_vm.domain_verifications WHERE tenant_id = $1 AND id = $2 AND verified_at IS NULL RETURNING 1) SELECT count(*)::int AS count FROM removed",
      [tenant, id]).pipe(Effect.map((removed) => removed === 1)),
    countPendingVerifications: (tenant) => count("verifications.count",
      "SELECT count(*)::int AS count FROM cmux_vm.domain_verifications WHERE tenant_id = $1 AND verified_at IS NULL", [tenant]),

    insertForwardAuth: (row) => sql.query("forwardAuths.insert",
      `INSERT INTO cmux_vm.tls_forward_auths (id, tenant_id, upstream_id, url, timeout_ms, header_names, auth_response_headers, protected_cookies, created_by, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6::text::jsonb, $7::text::jsonb, $8::text::jsonb, $9, $10, $11)`,
      [row.id, row.tenantId, row.upstreamId, row.url, row.timeoutMs, json(row.headerNames), json(row.authResponseHeaders), json(row.protectedCookies),
        row.createdBy, row.createdAt.toISOString(), row.updatedAt.toISOString()]).pipe(Effect.asVoid),
    listForwardAuths: (tenant) => forwardAuths("forwardAuths.list",
      `SELECT ${FORWARD_AUTH_COLUMNS} FROM cmux_vm.tls_forward_auths WHERE tenant_id = $1 ORDER BY created_at DESC, id`, [tenant]),
    findForwardAuth: (tenant, id) => forwardAuths("forwardAuths.find",
      `SELECT ${FORWARD_AUTH_COLUMNS} FROM cmux_vm.tls_forward_auths WHERE tenant_id = $1 AND id = $2`, [tenant, id]).pipe(Effect.map((rows) => rows[0] ?? null)),
    updateForwardAuth: (tenant, id, fields, at) => forwardAuths("forwardAuths.update",
      `UPDATE cmux_vm.tls_forward_auths SET url = $3, timeout_ms = $4, header_names = $5::text::jsonb, auth_response_headers = $6::text::jsonb,
       protected_cookies = $7::text::jsonb, updated_at = $8 WHERE tenant_id = $1 AND id = $2 RETURNING ${FORWARD_AUTH_COLUMNS}`,
      [tenant, id, fields.url, fields.timeoutMs, json(fields.headerNames), json(fields.authResponseHeaders), json(fields.protectedCookies), at.toISOString()],
    ).pipe(Effect.map((rows) => rows[0] ?? null)),
    deleteForwardAuth: (tenant, id) => sql.query("forwardAuths.delete", "DELETE FROM cmux_vm.tls_forward_auths WHERE tenant_id = $1 AND id = $2", [tenant, id]).pipe(Effect.asVoid),
    countForwardAuths: (tenant) => count("forwardAuths.count", "SELECT count(*)::int AS count FROM cmux_vm.tls_forward_auths WHERE tenant_id = $1", [tenant]),

    insertTlsRule: (row) => sql.query("tlsRules.insert",
      `INSERT INTO cmux_vm.tls_rules (id, tenant_id, upstream_id, domain, spec, vm_ids, forward_auth_id, created_by, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5::text::jsonb, $6::text::jsonb, $7, $8, $9, $10)`,
      [row.id, row.tenantId, row.upstreamId, row.domain, json(row.spec), json(row.vmIds), row.forwardAuthId, row.createdBy, row.createdAt.toISOString(), row.updatedAt.toISOString()],
    ).pipe(Effect.asVoid),
    listTlsRules: (tenant) => rules("tlsRules.list", `SELECT ${RULE_COLUMNS} FROM cmux_vm.tls_rules WHERE tenant_id = $1 ORDER BY created_at DESC, id DESC`, [tenant]),
    findTlsRule: (tenant, id) => rules("tlsRules.find", `SELECT ${RULE_COLUMNS} FROM cmux_vm.tls_rules WHERE tenant_id = $1 AND id = $2`, [tenant, id]).pipe(Effect.map((rows) => rows[0] ?? null)),
    updateTlsRule: (tenant, id, fields, at) => rules("tlsRules.update",
      `UPDATE cmux_vm.tls_rules SET domain = $3, spec = $4::text::jsonb, vm_ids = $5::text::jsonb, forward_auth_id = $6, updated_at = $7
       WHERE tenant_id = $1 AND id = $2 RETURNING ${RULE_COLUMNS}`,
      [tenant, id, fields.domain, json(fields.spec), json(fields.vmIds), fields.forwardAuthId, at.toISOString()]).pipe(Effect.map((rows) => rows[0] ?? null)),
    deleteTlsRule: (tenant, id) => sql.query("tlsRules.delete", "DELETE FROM cmux_vm.tls_rules WHERE tenant_id = $1 AND id = $2", [tenant, id]).pipe(Effect.asVoid),
    countTlsRules: (tenant) => count("tlsRules.count", "SELECT count(*)::int AS count FROM cmux_vm.tls_rules WHERE tenant_id = $1", [tenant]),
    countTlsRulesUsingForwardAuth: (tenant, id) => count("tlsRules.countForwardAuth",
      "SELECT count(*)::int AS count FROM cmux_vm.tls_rules WHERE tenant_id = $1 AND forward_auth_id = $2", [tenant, id]),
    countTlsRulesUnder: (tenant, domain) => count("tlsRules.countUnder",
      `SELECT count(*)::int AS count FROM cmux_vm.tls_rules WHERE tenant_id = $1
       AND (domain = $2 OR (char_length(domain) > char_length($2) + 1 AND right(domain, char_length($2) + 1) = '.' || $2))`, [tenant, domain]),
  };
};

export const sqlDomainStoreLayer: Layer.Layer<DomainStore, never, SqlClient> = Layer.effect(DomainStore, Effect.map(SqlClient, sqlDomainStore));

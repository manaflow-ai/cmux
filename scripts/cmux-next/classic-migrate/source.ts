import { readFileSync } from "node:fs"

// Reading classic. Both sources produce the same SubjectRows: every classic row the planner needs for one
// subject (a Stack user or a Stack team). Postgres reads run inside one READ ONLY transaction and only
// SELECT statements pass the guard; nothing here can write classic.

export type Subject = { kind: "user"; id: string } | { kind: "team"; id: string }

type Json = string | number | boolean | null | Json[] | { [k: string]: Json }
type Meta = { [k: string]: Json } | null

export interface ClassicUser {
  id: string
  primary_email: string | null
  display_name: string | null
  client_read_only_metadata: Meta
}
export interface ClassicTeam {
  id: string
  display_name: string
  client_read_only_metadata: Meta
  /** From the Stack team record (hexclave_teams.raw), read only to look for a personal-team marker. */
  server_metadata?: Meta
  client_metadata?: Meta
}

/** What the planner needs to tell whether a VM's owner team is its creator's personal Stack team. */
export interface OwnerTeamFacts {
  id: string
  team: ClassicTeam | null
  member_ids: string[]
  team_subscription_ids: string[]
}
export interface ClassicMembership {
  team_id: string
  user_id: string
}
export interface ClassicVm {
  id: string
  user_id: string
  owner_team_id: string | null
  billing_team_id: string | null
  provider: string
  provider_vm_id: string | null
  display_name: string | null
  slug: string | null
  image_id: string
  image_version: string | null
  status: string
  destroyed_at: string | null
  provider_metadata: Meta
}
export interface ClassicSnapshotRequest {
  vm_id: string
  idempotency_key: string
  status: string
  provider_snapshot_id: string | null
  snapshot_name: string | null
}
export interface ClassicPublication {
  id: string
  owner_user_id: string
  vm_id: string
  domain_id: string | null
  hostname: string
  access_mode: string
  state: string
}
export interface ClassicDomain {
  id: string
  owner_user_id: string
  hostname: string
  kind: string
}
export interface ClassicTunnel {
  id: string
  user_id: string
  provider_tunnel_id: string
  device_name: string | null
  tunnel_purpose: string
  revoked_at: string | null
}
export interface ClassicStripeCustomer {
  id: string
  stack_user_id: string
  stack_team_id: string | null
  email: string | null
}
export interface ClassicStripeSubscription {
  id: string
  customer_id: string
  stack_user_id: string
  stack_team_id: string | null
  status: string
  plan: string
  scope: string
  seats: number | null
}
export interface ClassicApiKey {
  id: string
  team_id: string
  stack_user_id: string
  key_prefix: string
  label: string
  revoked_at: string | null
}
export interface ClassicRouteToken {
  id: string
  team_id: string
  stack_user_id: string
  label: string
  vm_id: string | null
  expires_at: string
  revoked_at: string | null
}
export interface ClassicAppleSubscription {
  original_transaction_id: string
  user_id: string
  product_id: string
  plan_id: string
  status: string
  expires_at: string | null
}
export interface ClassicAdminPlanGrant {
  id: string
  email: string
  plan: string
  applied_user_id: string | null
  applied_at: string | null
  revoked_at: string | null
}

/** Every classic row the planner reads for one subject. Runs and vault transcripts are counted, never listed. */
export interface SubjectRows {
  subject: Subject
  users: ClassicUser[]
  teams: ClassicTeam[]
  memberships: ClassicMembership[]
  cloud_vms: ClassicVm[]
  cloud_vm_snapshot_requests: ClassicSnapshotRequest[]
  cloud_vm_publications: ClassicPublication[]
  cloud_vm_domains: ClassicDomain[]
  cloud_vm_tunnels: ClassicTunnel[]
  stripe_customers: ClassicStripeCustomer[]
  stripe_subscriptions: ClassicStripeSubscription[]
  coderouter_api_keys: ClassicApiKey[]
  coderouter_route_tokens: ClassicRouteToken[]
  apple_subscriptions: ClassicAppleSubscription[]
  admin_plan_grants: ClassicAdminPlanGrant[]
  /** Every Stack team a listed VM is owned by (owner_team_id other than the creator's user id). */
  owner_teams: OwnerTeamFacts[]
  runs_count: number
  vault_sessions_count: number
}

export interface ClassicSource {
  readonly kind: "postgres" | "fixture"
  readonly label: string
  read(subject: Subject): Promise<SubjectRows>
}

// ---------------------------------------------------------------------------------------------------------------
// Fixture: a JSON file of the same tables (snake_case columns), filtered exactly as the SQL below filters.

export interface FixtureFile {
  stack_project_id?: string
  tables: {
    hexclave_users?: ClassicUser[]
    hexclave_teams?: ClassicTeam[]
    hexclave_team_memberships?: ClassicMembership[]
    cloud_vms?: ClassicVm[]
    cloud_vm_snapshot_requests?: ClassicSnapshotRequest[]
    cloud_vm_publications?: ClassicPublication[]
    cloud_vm_domains?: ClassicDomain[]
    cloud_vm_tunnels?: ClassicTunnel[]
    stripe_customers?: ClassicStripeCustomer[]
    stripe_subscriptions?: ClassicStripeSubscription[]
    coderouter_api_keys?: ClassicApiKey[]
    coderouter_route_tokens?: ClassicRouteToken[]
    apple_subscriptions?: ClassicAppleSubscription[]
    admin_plan_grants?: ClassicAdminPlanGrant[]
    runs?: { id: string; user_id: string; owner_team_id: string | null }[]
    vault_sessions?: { id: string; user_id: string }[]
  }
}

export const readFixture = (path: string): FixtureFile => JSON.parse(readFileSync(path, "utf8")) as FixtureFile

/** The Stack teams that own `vms`, other than a creator's own user id (classic's synthetic personal team). */
export const ownerTeamIds = (vms: ClassicVm[]) =>
  [...new Set(vms.flatMap((v) => (v.owner_team_id && v.owner_team_id !== v.user_id ? [v.owner_team_id] : [])))].sort()

export const fixtureSource = (fixture: FixtureFile, label: string): ClassicSource => ({
  kind: "fixture",
  label,
  read: async (subject) => {
    const rows = readFixtureSubject(fixture, subject)
    const t = fixture.tables
    const owner_teams = ownerTeamIds(rows.cloud_vms).map((id) => ({
      id,
      team: (t.hexclave_teams ?? []).find((r) => r.id === id) ?? null,
      member_ids: (t.hexclave_team_memberships ?? [])
        .filter((m) => m.team_id === id)
        .map((m) => m.user_id)
        .sort(),
      team_subscription_ids: (t.stripe_subscriptions ?? [])
        .filter((r) => r.stack_team_id === id)
        .map((r) => r.id)
        .sort(),
    }))
    return { ...rows, owner_teams }
  },
})

const readFixtureSubject = (fixture: FixtureFile, subject: Subject): Omit<SubjectRows, "owner_teams"> => {
    const t = fixture.tables
    const all = <T>(rows: T[] | undefined): T[] => rows ?? []
    const lower = (s: string | null | undefined) => (s ?? "").toLowerCase()
    if (subject.kind === "user") {
      const u = subject.id
      const users = all(t.hexclave_users).filter((r) => r.id === u)
      const memberships = all(t.hexclave_team_memberships).filter((r) => r.user_id === u)
      const teamIds = new Set(memberships.map((m) => m.team_id))
      const vms = all(t.cloud_vms).filter((r) => r.user_id === u || r.owner_team_id === u)
      const vmIds = new Set(vms.map((v) => v.id))
      const customers = all(t.stripe_customers).filter((r) => r.stack_user_id === u && r.stack_team_id === null)
      const customerIds = new Set(customers.map((c) => c.id))
      const email = lower(users[0]?.primary_email)
      return {
        subject,
        users,
        teams: all(t.hexclave_teams).filter((r) => teamIds.has(r.id)),
        memberships,
        cloud_vms: vms,
        cloud_vm_snapshot_requests: all(t.cloud_vm_snapshot_requests).filter((r) => vmIds.has(r.vm_id)),
        cloud_vm_publications: all(t.cloud_vm_publications).filter(
          (r) => vmIds.has(r.vm_id) || r.owner_user_id === u,
        ),
        cloud_vm_domains: all(t.cloud_vm_domains).filter((r) => r.owner_user_id === u),
        cloud_vm_tunnels: all(t.cloud_vm_tunnels).filter((r) => r.user_id === u && r.revoked_at === null),
        stripe_customers: customers,
        stripe_subscriptions: all(t.stripe_subscriptions).filter((r) => customerIds.has(r.customer_id)),
        coderouter_api_keys: all(t.coderouter_api_keys).filter((r) => r.team_id === u && r.revoked_at === null),
        coderouter_route_tokens: all(t.coderouter_route_tokens).filter(
          (r) => r.team_id === u && r.revoked_at === null,
        ),
        apple_subscriptions: all(t.apple_subscriptions).filter((r) => r.user_id === u),
        admin_plan_grants: all(t.admin_plan_grants).filter(
          (r) => r.applied_user_id === u || (email !== "" && lower(r.email) === email),
        ),
        runs_count: all(t.runs).filter((r) => r.user_id === u && (r.owner_team_id === null || r.owner_team_id === u))
          .length,
        vault_sessions_count: all(t.vault_sessions).filter((r) => r.user_id === u).length,
      }
    }
    const team = subject.id
    const memberships = all(t.hexclave_team_memberships).filter((r) => r.team_id === team)
    const userIds = new Set(memberships.map((m) => m.user_id))
    const vms = all(t.cloud_vms).filter((r) => r.owner_team_id === team)
    const vmIds = new Set(vms.map((v) => v.id))
    const publications = all(t.cloud_vm_publications).filter((r) => vmIds.has(r.vm_id))
    const domainIds = new Set(publications.flatMap((p) => (p.domain_id ? [p.domain_id] : [])))
    const customers = all(t.stripe_customers).filter((r) => r.stack_team_id === team)
    const customerIds = new Set(customers.map((c) => c.id))
    return {
      subject,
      users: all(t.hexclave_users).filter((r) => userIds.has(r.id)),
      teams: all(t.hexclave_teams).filter((r) => r.id === team),
      memberships,
      cloud_vms: vms,
      cloud_vm_snapshot_requests: all(t.cloud_vm_snapshot_requests).filter((r) => vmIds.has(r.vm_id)),
      cloud_vm_publications: publications,
      cloud_vm_domains: all(t.cloud_vm_domains).filter((r) => domainIds.has(r.id)),
      cloud_vm_tunnels: [],
      stripe_customers: customers,
      stripe_subscriptions: all(t.stripe_subscriptions).filter((r) => customerIds.has(r.customer_id)),
      coderouter_api_keys: all(t.coderouter_api_keys).filter((r) => r.team_id === team && r.revoked_at === null),
      coderouter_route_tokens: all(t.coderouter_route_tokens).filter(
        (r) => r.team_id === team && r.revoked_at === null,
      ),
      apple_subscriptions: [],
      admin_plan_grants: [],
      runs_count: all(t.runs).filter((r) => r.owner_team_id === team).length,
      vault_sessions_count: 0,
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Postgres: one reserved connection, `BEGIN READ ONLY`, a check that the server agrees, SELECTs only, ROLLBACK.

/** The subset of a Postgres connection the reader uses (Bun's ReservedSQL fits it). */
export interface PgConnection {
  unsafe(text: string, params?: unknown[]): Promise<ReadonlyArray<Record<string, unknown>>>
  release(): void | Promise<void>
}

export type ReadOnlyQuery = (text: string, params?: unknown[]) => Promise<Record<string, unknown>[]>

export class ReadOnlyViolation extends Error {}

/** Only a single SELECT (or WITH … SELECT) passes; anything else is refused before it reaches the server. */
export const assertSelectOnly = (text: string) => {
  const sql = text.trim().replace(/;\s*$/, "")
  if (!/^(select|with)\b/i.test(sql) || sql.includes(";"))
    throw new ReadOnlyViolation(`refused a non-SELECT statement on classic: ${sql.slice(0, 60)}`)
  if (/\b(insert|update|delete|merge|truncate|alter|drop|create|grant|copy|call|lock)\b/i.test(sql.replace(/'[^']*'/g, "")))
    throw new ReadOnlyViolation(`refused a statement with a write keyword on classic: ${sql.slice(0, 60)}`)
}

/** Every classic statement is cut off after this long (SET LOCAL, so it ends with the transaction). */
export const STATEMENT_TIMEOUT_MS = 15_000

/** Runs `fn` inside one READ ONLY transaction with a statement timeout, and always rolls it back. */
export const withReadOnlyTransaction = async <T>(
  conn: PgConnection,
  fn: (q: ReadOnlyQuery) => Promise<T>,
  statementTimeoutMs = STATEMENT_TIMEOUT_MS,
) => {
  if (!Number.isSafeInteger(statementTimeoutMs) || statementTimeoutMs <= 0)
    throw new Error(`bad statement timeout ${statementTimeoutMs}`)
  try {
    await conn.unsafe("BEGIN READ ONLY")
    try {
      await conn.unsafe("SET TRANSACTION READ ONLY")
      await conn.unsafe(`SET LOCAL statement_timeout = ${statementTimeoutMs}`)
      const [row] = await conn.unsafe("SHOW transaction_read_only")
      if (row?.["transaction_read_only"] !== "on")
        throw new ReadOnlyViolation("the classic connection did not enter a read-only transaction")
      return await fn(async (text, params) => {
        assertSelectOnly(text)
        return (await conn.unsafe(text, params ?? [])).map(normalizeRow)
      })
    } finally {
      await conn.unsafe("ROLLBACK")
    }
  } finally {
    await conn.release()
  }
}

const normalizeRow = (row: Record<string, unknown>) => {
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(row)) out[k] = v instanceof Date ? v.toISOString() : v
  return out
}

/** Reads one subject's rows, then the facts about every Stack team that owns one of its VMs. */
export const readSubject = async (q: ReadOnlyQuery, subject: Subject): Promise<SubjectRows> => {
  const base = await readSubjectBase(q, subject)
  const ids = ownerTeamIds(base.cloud_vms)
  const teams = (await q(
    `select id, display_name, client_read_only_metadata, raw->'server_metadata' as server_metadata,
       raw->'client_metadata' as client_metadata from hexclave_teams where id = any($1::text[]) order by id`,
    [ids],
  )) as unknown as ClassicTeam[]
  const members = (await q(
    `select team_id, user_id from hexclave_team_memberships where team_id = any($1::text[]) order by team_id, user_id`,
    [ids],
  )) as unknown as ClassicMembership[]
  const subs = (await q(
    `select id, stack_team_id from stripe_subscriptions where stack_team_id = any($1::text[]) order by id`,
    [ids],
  )) as unknown as { id: string; stack_team_id: string }[]
  return {
    ...base,
    owner_teams: ids.map((id) => ({
      id,
      team: teams.find((t) => t.id === id) ?? null,
      member_ids: members.filter((m) => m.team_id === id).map((m) => m.user_id),
      team_subscription_ids: subs.filter((r) => r.stack_team_id === id).map((r) => r.id),
    })),
  }
}

/** Every statement takes `$1` = the subject id. */
const readSubjectBase = async (q: ReadOnlyQuery, subject: Subject): Promise<Omit<SubjectRows, "owner_teams">> => {
  const id = subject.id
  const rows = async <T>(text: string, params: unknown[] = [id]) => (await q(text, params)) as unknown as T[]
  const count = async (text: string) => Number((await q(text, [id]))[0]?.["n"] ?? 0)
  const vmCols = `id::text, user_id, owner_team_id, billing_team_id, provider::text, provider_vm_id, display_name, slug,
    image_id, image_version, status::text, destroyed_at, provider_metadata`
  const snapReqs = `select vm_id::text, idempotency_key, status, provider_snapshot_id, snapshot_name
    from cloud_vm_snapshot_requests where vm_id::text = any($1::text[]) order by vm_id, idempotency_key`
  const subs = `select id, customer_id, stack_user_id, stack_team_id, status, plan, scope, seats
    from stripe_subscriptions where customer_id = any($1::text[]) order by id`
  if (subject.kind === "user") {
    const users = await rows<ClassicUser>(
      `select id, primary_email, display_name, client_read_only_metadata from hexclave_users where id = $1`,
    )
    const memberships = await rows<ClassicMembership>(
      `select team_id, user_id from hexclave_team_memberships where user_id = $1 order by team_id`,
    )
    const vms = await rows<ClassicVm>(
      `select ${vmCols} from cloud_vms where user_id = $1 or owner_team_id = $1 order by id`,
    )
    const vmIds = vms.map((v) => v.id)
    const customers = await rows<ClassicStripeCustomer>(
      `select id, stack_user_id, stack_team_id, email from stripe_customers
       where stack_user_id = $1 and stack_team_id is null order by id`,
    )
    return {
      subject,
      users,
      teams: await rows<ClassicTeam>(
        `select t.id, t.display_name, t.client_read_only_metadata, t.raw->'server_metadata' as server_metadata,
         t.raw->'client_metadata' as client_metadata from hexclave_teams t
         join hexclave_team_memberships m on m.team_id = t.id where m.user_id = $1 order by t.id`,
      ),
      memberships,
      cloud_vms: vms,
      cloud_vm_snapshot_requests: await rows<ClassicSnapshotRequest>(snapReqs, [vmIds]),
      cloud_vm_publications: await rows<ClassicPublication>(
        `select id::text, owner_user_id, vm_id::text, domain_id::text, hostname, access_mode, state
         from cloud_vm_publications where owner_user_id = $1 or vm_id::text = any($2::text[]) order by id`,
        [id, vmIds],
      ),
      cloud_vm_domains: await rows<ClassicDomain>(
        `select id::text, owner_user_id, hostname, kind from cloud_vm_domains where owner_user_id = $1 order by id`,
      ),
      cloud_vm_tunnels: await rows<ClassicTunnel>(
        `select id::text, user_id, provider_tunnel_id, device_name, tunnel_purpose::text, revoked_at
         from cloud_vm_tunnels where user_id = $1 and revoked_at is null order by id`,
      ),
      stripe_customers: customers,
      stripe_subscriptions: await rows<ClassicStripeSubscription>(subs, [customers.map((c) => c.id)]),
      coderouter_api_keys: await rows<ClassicApiKey>(
        `select id::text, team_id, stack_user_id, key_prefix, label, revoked_at from coderouter_api_keys
         where team_id = $1 and revoked_at is null order by id`,
      ),
      coderouter_route_tokens: await rows<ClassicRouteToken>(
        `select id::text, team_id, stack_user_id, label, vm_id, expires_at, revoked_at from coderouter_route_tokens
         where team_id = $1 and revoked_at is null order by id`,
      ),
      apple_subscriptions: await rows<ClassicAppleSubscription>(
        `select original_transaction_id, user_id, product_id, plan_id, status, expires_at from apple_subscriptions
         where user_id = $1 order by original_transaction_id`,
      ),
      admin_plan_grants: await rows<ClassicAdminPlanGrant>(
        `select g.id::text, g.email, g.plan, g.applied_user_id, g.applied_at, g.revoked_at from admin_plan_grants g
         where g.applied_user_id = $1 or lower(g.email) = (select lower(primary_email) from hexclave_users where id = $1)
         order by g.id`,
      ),
      runs_count: await count(
        `select count(*)::int as n from runs where user_id = $1 and (owner_team_id is null or owner_team_id = $1)`,
      ),
      vault_sessions_count: await count(`select count(*)::int as n from vault_sessions where user_id = $1`),
    }
  }
  const vms = await rows<ClassicVm>(`select ${vmCols} from cloud_vms where owner_team_id = $1 order by id`)
  const vmIds = vms.map((v) => v.id)
  const publications = await rows<ClassicPublication>(
    `select id::text, owner_user_id, vm_id::text, domain_id::text, hostname, access_mode, state
     from cloud_vm_publications where vm_id::text = any($1::text[]) order by id`,
    [vmIds],
  )
  const customers = await rows<ClassicStripeCustomer>(
    `select id, stack_user_id, stack_team_id, email from stripe_customers where stack_team_id = $1 order by id`,
  )
  return {
    subject,
    users: await rows<ClassicUser>(
      `select u.id, u.primary_email, u.display_name, u.client_read_only_metadata from hexclave_users u
       join hexclave_team_memberships m on m.user_id = u.id where m.team_id = $1 order by u.id`,
    ),
    teams: await rows<ClassicTeam>(
      `select id, display_name, client_read_only_metadata, raw->'server_metadata' as server_metadata,
         raw->'client_metadata' as client_metadata from hexclave_teams where id = $1`,
    ),
    memberships: await rows<ClassicMembership>(
      `select team_id, user_id from hexclave_team_memberships where team_id = $1 order by user_id`,
    ),
    cloud_vms: vms,
    cloud_vm_snapshot_requests: await rows<ClassicSnapshotRequest>(snapReqs, [vmIds]),
    cloud_vm_publications: publications,
    cloud_vm_domains: await rows<ClassicDomain>(
      `select id::text, owner_user_id, hostname, kind from cloud_vm_domains where id::text = any($1::text[]) order by id`,
      [publications.flatMap((p) => (p.domain_id ? [p.domain_id] : []))],
    ),
    cloud_vm_tunnels: [],
    stripe_customers: customers,
    stripe_subscriptions: await rows<ClassicStripeSubscription>(subs, [customers.map((c) => c.id)]),
    coderouter_api_keys: await rows<ClassicApiKey>(
      `select id::text, team_id, stack_user_id, key_prefix, label, revoked_at from coderouter_api_keys
       where team_id = $1 and revoked_at is null order by id`,
    ),
    coderouter_route_tokens: await rows<ClassicRouteToken>(
      `select id::text, team_id, stack_user_id, label, vm_id, expires_at, revoked_at from coderouter_route_tokens
       where team_id = $1 and revoked_at is null order by id`,
    ),
    apple_subscriptions: [],
    admin_plan_grants: [],
    runs_count: await count(`select count(*)::int as n from runs where owner_team_id = $1`),
    vault_sessions_count: 0,
  }
}

export class ClassicHostRefused extends Error {}

/**
 * Refuses a classic database URL whose host is not on CLASSIC_DB_HOST_ALLOW (a comma list of classic staging
 * hosts; required, no default). `allowProductionRead` (the CLI's --allow-production-read, for a later runbook
 * step) skips the list; the read stays READ ONLY either way.
 */
export const checkClassicHost = (url: string, allowList: string | undefined, allowProductionRead: boolean) => {
  let host: string
  try {
    host = new URL(url).hostname.toLowerCase()
  } catch {
    throw new ClassicHostRefused("CLASSIC_DATABASE_URL is not a URL")
  }
  if (allowProductionRead) return { host, via: "allow-production-read" as const }
  const allowed = (allowList ?? "")
    .split(",")
    .map((h) => h.trim().toLowerCase())
    .filter((h) => h !== "")
  if (allowed.length === 0)
    throw new ClassicHostRefused(
      "CLASSIC_DB_HOST_ALLOW is required: a comma list of classic staging database hosts (no default)",
    )
  if (!allowed.includes(host))
    throw new ClassicHostRefused(
      `classic database host ${host} is not on CLASSIC_DB_HOST_ALLOW (${allowed.join(", ")}); a production read needs --allow-production-read`,
    )
  return { host, via: "allowlist" as const }
}

/** Opens a connection (CLASSIC_DATABASE_URL, a read-only role or replica) and reads inside READ ONLY. */
export const postgresSource = (connect: () => Promise<PgConnection>, label: string): ClassicSource => ({
  kind: "postgres",
  label,
  read: async (subject) => withReadOnlyTransaction(await connect(), (q) => readSubject(q, subject)),
})

/** Bun's built-in Postgres client, one reserved connection per read. */
export const bunPostgresConnect = (url: string) => async (): Promise<PgConnection> => {
  const { SQL } = await import("bun")
  const sql = new SQL(url, { max: 1 })
  const reserved = await sql.reserve()
  return {
    unsafe: async (text, params) => (await reserved.unsafe(text, params ?? [])) as Record<string, unknown>[],
    release: async () => {
      reserved.release()
      await sql.close()
    },
  }
}

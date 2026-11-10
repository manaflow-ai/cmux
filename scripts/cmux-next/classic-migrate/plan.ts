import { migrationIdFor, personalTeamIdFor, sharedTeamIdFor, userIdFor } from "./ids.ts"
import type { ClassicTeam, ClassicVm, OwnerTeamFacts, Subject, SubjectRows } from "./source.ts"

// The planner: pure, from one subject's classic rows to the action for every object. The dry run prints
// it; apply executes its `copy` entries. Same rows in, same bytes out (stable order, no clock).

export type Action = "carried" | "copy" | "link" | "not-migrated" | "needs-decision"

/** Where a copied machine lands in the VM API. A personal tenant is resolved at apply time. */
export type TenantRef = { kind: "team"; tenant_id: string } | { kind: "personal"; stack_user_id: string; user_id: string }

export interface CopySpec {
  classic_vm_id: string
  upstream_vm_id: string
  next_team_id: string
  tenant: TenantRef
  creator_user_id: string
  name: string
  size: string | null
}

export interface PlanEntry {
  kind: string
  classic_id: string
  action: Action
  summary: string
  next?: Record<string, string>
  reason?: string
  /** cloud_vm only: whether the VM is its creator's personal machine, and which rule said so. */
  personal_reason?: string
  copy?: CopySpec
}

export interface Plan {
  version: 1
  migration_id: string
  stack_project_id: string
  subject: Subject & { next_team_id: string }
  source: string
  counts: Record<Action, number>
  entries: PlanEntry[]
}

const KIND_ORDER = [
  "user",
  "team",
  "membership",
  "plan_metadata",
  "admin_plan_grant",
  "cloud_vm",
  "classic_snapshot",
  "stripe_customer",
  "cloud_vm_publication",
  "cloud_vm_domain",
  "cloud_vm_tunnel",
  "coderouter_api_key",
  "coderouter_route_token",
  "apple_subscription",
  "runs",
  "vault_sessions",
]

const REASONS = {
  destroyed: "destroyed on classic; nothing to copy",
  failed: "failed on classic; no running VM to snapshot",
  provisioning: "still provisioning on classic; re-plan once it is running",
  noUpstream: "no provider VM id on classic; nothing to snapshot",
  classicSnapshot: "a classic Freestyle snapshot stays on classic; the copy carries the VM's current state",
  publication: "public URL routes to the classic VM and stays on classic; publish the copy again on NEXT",
  domain: "domain verification and TLS live in classic's provider config; add the domain again on NEXT",
  tunnel: "Mac tunnel enrollment is classic-only; NEXT enrolls its own mesh devices",
  apiKey: "stored as a hash, cannot be re-keyed; stays valid on classic (NEXT keys are cmuxvm_sk_)",
  routeToken: "CodeRouter route token for classic's /v1 proxy; stays valid on classic",
  apple: "Apple IAP subscription stays on classic billing (App Store owns renewals)",
  grantOpen: "unapplied grant; classic applies it at sign-in into Stack plan metadata, which NEXT then reads",
  runs: "classic run history stays on classic",
  vault: "transcripts stay in the classic vault",
} as const

const planOf = (meta: SubjectRows["users"][number]["client_read_only_metadata"]) => {
  const pick = (k: string) => {
    const v = meta?.[k]
    if (v === undefined || v === null) return "none"
    if (typeof v === "string") return v
    if (typeof v === "object" && !Array.isArray(v) && typeof v["plan"] === "string") return v["plan"]
    return JSON.stringify(v)
  }
  return { cmuxPlan: pick("cmuxPlan"), cmuxVmPlan: pick("cmuxVmPlan") }
}

export interface Ownership {
  owner: "personal" | "shared" | "needs-decision"
  reason: string
}

const PERSONAL_MARKERS = ["isPersonal", "is_personal", "personal", "personalTeam", "cmuxPersonalTeam"]

const personalMarker = (team: ClassicTeam): { value: boolean; where: string } | null => {
  const places = [
    ["client_read_only_metadata", team.client_read_only_metadata],
    ["server_metadata", team.server_metadata],
    ["client_metadata", team.client_metadata],
  ] as const
  for (const [where, meta] of places)
    for (const key of PERSONAL_MARKERS) {
      const v = meta?.[key]
      if (typeof v === "boolean") return { value: v, where: `${where}.${key}` }
    }
  return null
}

/**
 * Whether a classic VM is its creator's personal machine. Classic writes owner_team_id =
 * coalesce(owner_team_id, billing_team_id, user_id), usually the creator's personal Stack team; Stack marks no
 * team personal, so a team with exactly one member (the creator) and no team subscription counts as personal.
 * Anything the rules cannot settle is `needs-decision`, never a guess.
 */
export const classifyVm = (vm: ClassicVm, teams: ReadonlyMap<string, OwnerTeamFacts>): Ownership => {
  const owner = vm.owner_team_id ?? ""
  if (owner === "" || owner === vm.user_id)
    return { owner: "personal", reason: "owner_team_id is the creator's user id (classic's synthetic personal team)" }
  const f = teams.get(owner)
  if (!f || !f.team) return { owner: "needs-decision", reason: `owner team ${owner} is not in classic's hexclave mirror` }
  const marker = personalMarker(f.team)
  if (marker)
    return marker.value
      ? { owner: "personal", reason: `owner team ${owner} is marked personal (${marker.where})` }
      : { owner: "shared", reason: `owner team ${owner} is marked not personal (${marker.where})` }
  const members = f.member_ids
  if (members.length >= 2) return { owner: "shared", reason: `owner team ${owner} has ${members.length} members` }
  if (members.length === 0) return { owner: "needs-decision", reason: `owner team ${owner} has no members in the mirror` }
  if (members[0] !== vm.user_id)
    return { owner: "needs-decision", reason: `owner team ${owner}'s only member is ${members[0]}, not the creator` }
  if (f.team_subscription_ids.length > 0)
    return {
      owner: "needs-decision",
      reason: `owner team ${owner}'s only member is the creator, but it has a team subscription (${f.team_subscription_ids.join(", ")})`,
    }
  return { owner: "personal", reason: `owner team ${owner}'s only member is the creator and it has no team subscription` }
}

const vmName = (vm: ClassicVm) => vm.display_name ?? vm.slug ?? vm.provider_vm_id ?? vm.id
const vmSize = (vm: ClassicVm) => {
  const s = vm.provider_metadata?.["size"]
  return typeof s === "string" ? s : null
}

export const buildPlan = (rows: SubjectRows, stackProjectId: string, source: string): Plan => {
  const { subject } = rows
  const entries: PlanEntry[] = []
  const add = (e: PlanEntry) => entries.push(e)
  const nextUser = (stackUserId: string) => userIdFor(stackProjectId, stackUserId)
  const subjectTeam =
    subject.kind === "user" ? personalTeamIdFor(nextUser(subject.id)) : sharedTeamIdFor(stackProjectId, subject.id)

  // Identity, teams, memberships, plan: the same Stack project, so NEXT already has them. Nothing to write.
  for (const u of rows.users) {
    add({
      kind: "user",
      classic_id: u.id,
      action: "carried",
      summary: u.primary_email ?? u.display_name ?? u.id,
      next: {
        user_id: nextUser(u.id),
        ...(subject.kind === "user" && u.id === subject.id ? { personal_team_id: subjectTeam } : {}),
      },
      reason: "same Stack project; NEXT derives the id and materializes the user at first sign-in (user.ensure)",
    })
    if (subject.kind === "user" && u.id === subject.id) {
      const p = planOf(u.client_read_only_metadata)
      add({
        kind: "plan_metadata",
        classic_id: u.id,
        action: "carried",
        summary: `cmuxPlan=${p.cmuxPlan} cmuxVmPlan=${p.cmuxVmPlan}`,
        next: { team_id: subjectTeam },
        reason:
          "Stack clientReadOnlyMetadata, read by NEXT as is (production counts paid plans only with CLOUD_PLAN_ENTITLEMENTS on)",
      })
    }
  }
  if (subject.kind === "user" && !rows.users.some((u) => u.id === subject.id))
    add({
      kind: "user",
      classic_id: subject.id,
      action: "carried",
      summary: "(not in classic's hexclave mirror)",
      next: { user_id: nextUser(subject.id), personal_team_id: subjectTeam },
      reason: "same Stack project; the id derives from the Stack user id",
    })
  // Stack teams that are some VM creator's personal team: their VMs land in the creator's NEXT personal team.
  const facts = new Map(rows.owner_teams.map((f) => [f.id, f]))
  const personalStackTeams = new Set(
    rows.cloud_vms.flatMap((vm) =>
      vm.owner_team_id && vm.owner_team_id !== vm.user_id && classifyVm(vm, facts).owner === "personal"
        ? [vm.owner_team_id]
        : [],
    ),
  )
  for (const t of rows.teams) {
    add({
      kind: "team",
      classic_id: t.id,
      action: "carried",
      summary: personalStackTeams.has(t.id)
        ? `${t.display_name} (a personal Stack team: its VMs land in the creator's NEXT personal team)`
        : t.display_name,
      next: { team_id: sharedTeamIdFor(stackProjectId, t.id), vm_api_tenant: t.id },
      reason: "NEXT mirrors Stack teams (webhook + user.teams.list repair)",
    })
    if (subject.kind === "team" && t.id === subject.id) {
      const p = planOf(t.client_read_only_metadata)
      add({
        kind: "plan_metadata",
        classic_id: t.id,
        action: "carried",
        summary: `cmuxPlan=${p.cmuxPlan} cmuxVmPlan=${p.cmuxVmPlan}`,
        next: { team_id: subjectTeam },
        reason:
          "Stack clientReadOnlyMetadata, read by NEXT as is (production counts paid plans only with CLOUD_PLAN_ENTITLEMENTS on)",
      })
    }
  }
  if (subject.kind === "team" && !rows.teams.some((t) => t.id === subject.id))
    add({
      kind: "team",
      classic_id: subject.id,
      action: "carried",
      summary: "(not in classic's hexclave mirror)",
      next: { team_id: subjectTeam, vm_api_tenant: subject.id },
      reason: "same Stack project; the id derives from the Stack team id",
    })
  for (const m of rows.memberships)
    add({
      kind: "membership",
      classic_id: `${m.team_id}/${m.user_id}`,
      action: "carried",
      summary: `user ${m.user_id} in team ${m.team_id}`,
      next: { team_id: sharedTeamIdFor(stackProjectId, m.team_id), user_id: nextUser(m.user_id) },
      reason: "NEXT mirrors Stack memberships",
    })
  for (const g of rows.admin_plan_grants) {
    if (g.revoked_at !== null) continue
    add(
      g.applied_at !== null
        ? {
            kind: "admin_plan_grant",
            classic_id: g.id,
            action: "carried",
            summary: `${g.plan} for ${g.email}`,
            reason: "already applied into Stack plan metadata, which NEXT reads",
          }
        : {
            kind: "admin_plan_grant",
            classic_id: g.id,
            action: "not-migrated",
            summary: `${g.plan} for ${g.email}`,
            reason: REASONS.grantOpen,
          },
    )
  }

  // VMs: copy each live one the subject owns into the subject's NEXT team.
  for (const vm of rows.cloud_vms) {
    const own = classifyVm(vm, facts)
    const base = {
      kind: "cloud_vm",
      classic_id: vm.id,
      summary: `${vmName(vm)} (${vm.status}, ${vm.provider})`,
      personal_reason: `${own.owner}: ${own.reason}`,
    }
    const life =
      vm.status === "destroyed" || vm.destroyed_at !== null
        ? REASONS.destroyed
        : vm.status === "failed"
          ? REASONS.failed
          : vm.status === "provisioning"
            ? REASONS.provisioning
            : vm.provider !== "freestyle"
              ? `provider ${vm.provider} has no VM API import`
              : vm.provider_vm_id === null
                ? REASONS.noUpstream
                : null
    if (life !== null || vm.provider_vm_id === null) {
      add({ ...base, action: "not-migrated", reason: life ?? REASONS.noUpstream })
      continue
    }
    if (own.owner === "needs-decision") {
      add({ ...base, action: "needs-decision", reason: `owner unclear: ${own.reason}; decide personal or team, then re-plan` })
      continue
    }
    const elsewhere =
      subject.kind === "user"
        ? own.owner === "shared"
          ? `owned by Stack team ${vm.owner_team_id}; it migrates with --team ${vm.owner_team_id}`
          : vm.user_id !== subject.id
            ? `personal VM of user ${vm.user_id}; it migrates with --user ${vm.user_id}`
            : null
        : own.owner === "personal"
          ? `Stack team ${subject.id} is ${vm.user_id}'s personal team; it migrates with --user ${vm.user_id}`
          : null
    if (elsewhere !== null) {
      add({ ...base, action: "not-migrated", reason: elsewhere })
      continue
    }
    const creator = nextUser(vm.user_id)
    const tenant: TenantRef =
      subject.kind === "team"
        ? { kind: "team", tenant_id: subject.id }
        : { kind: "personal", stack_user_id: subject.id, user_id: creator }
    add({
      ...base,
      action: "copy",
      next: {
        team_id: subjectTeam,
        vm_api_tenant: tenant.kind === "team" ? tenant.tenant_id : "personal tenant (resolved at apply)",
        creator_user_id: creator,
      },
      reason: "snapshot the upstream VM, import it under the NEXT tenant, create a machine from it; classic keeps its VM",
      copy: {
        classic_vm_id: vm.id,
        upstream_vm_id: vm.provider_vm_id,
        next_team_id: subjectTeam,
        tenant,
        creator_user_id: creator,
        name: vmName(vm),
        size: vmSize(vm),
      },
    })
  }
  for (const s of rows.cloud_vm_snapshot_requests) {
    if (s.status !== "succeeded") continue
    add({
      kind: "classic_snapshot",
      classic_id: s.provider_snapshot_id ?? `${s.vm_id}/${s.idempotency_key}`,
      action: "not-migrated",
      summary: `${s.snapshot_name ?? "(unnamed)"} of VM ${s.vm_id}`,
      reason: REASONS.classicSnapshot,
    })
  }

  // Billing: customers and subscriptions stay in Stripe; NEXT needs only the link record.
  for (const c of rows.stripe_customers) {
    const subs = rows.stripe_subscriptions.filter((s) => s.customer_id === c.id)
    add({
      kind: "stripe_customer",
      classic_id: c.id,
      action: "link",
      summary: `${c.email ?? "(no email)"}; subscriptions: ${subs.map((s) => `${s.id} ${s.plan} ${s.status}`).join(", ") || "none"}`,
      next: { team_id: subjectTeam },
      reason: "report only: NEXT links the customer to this team (team billing link); nothing is written by this tool",
    })
  }

  for (const p of rows.cloud_vm_publications)
    add({
      kind: "cloud_vm_publication",
      classic_id: p.id,
      action: "not-migrated",
      summary: `${p.hostname} -> VM ${p.vm_id} (${p.access_mode}, ${p.state})`,
      reason: REASONS.publication,
    })
  for (const d of rows.cloud_vm_domains)
    add({
      kind: "cloud_vm_domain",
      classic_id: d.id,
      action: "not-migrated",
      summary: `${d.hostname} (${d.kind})`,
      reason: REASONS.domain,
    })
  for (const t of rows.cloud_vm_tunnels)
    add({
      kind: "cloud_vm_tunnel",
      classic_id: t.id,
      action: "not-migrated",
      summary: `${t.device_name ?? t.provider_tunnel_id} (${t.tunnel_purpose})`,
      reason: REASONS.tunnel,
    })
  for (const k of rows.coderouter_api_keys)
    add({
      kind: "coderouter_api_key",
      classic_id: k.id,
      action: "not-migrated",
      summary: `${k.key_prefix}… "${k.label}"`,
      reason: REASONS.apiKey,
    })
  for (const k of rows.coderouter_route_tokens)
    add({
      kind: "coderouter_route_token",
      classic_id: k.id,
      action: "not-migrated",
      summary: `"${k.label}"${k.vm_id ? ` bound to VM ${k.vm_id}` : ""}`,
      reason: REASONS.routeToken,
    })
  for (const a of rows.apple_subscriptions)
    add({
      kind: "apple_subscription",
      classic_id: a.original_transaction_id,
      action: "not-migrated",
      summary: `${a.product_id} (${a.status})`,
      reason: REASONS.apple,
    })
  if (rows.runs_count > 0)
    add({
      kind: "runs",
      classic_id: subject.id,
      action: "not-migrated",
      summary: `${rows.runs_count} runs`,
      reason: REASONS.runs,
    })
  if (rows.vault_sessions_count > 0)
    add({
      kind: "vault_sessions",
      classic_id: subject.id,
      action: "not-migrated",
      summary: `${rows.vault_sessions_count} transcripts`,
      reason: REASONS.vault,
    })

  entries.sort(
    (a, b) =>
      KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind) ||
      (a.classic_id < b.classic_id ? -1 : a.classic_id > b.classic_id ? 1 : 0),
  )
  const counts: Record<Action, number> = { carried: 0, copy: 0, link: 0, "not-migrated": 0, "needs-decision": 0 }
  for (const e of entries) counts[e.action]++
  return {
    version: 1,
    migration_id: migrationIdFor(stackProjectId, subject),
    stack_project_id: stackProjectId,
    subject: { ...subject, next_team_id: subjectTeam },
    source,
    counts,
    entries,
  }
}

export const copiesOf = (plan: Plan): CopySpec[] =>
  plan.entries.flatMap((e) => (e.action === "copy" && e.copy ? [e.copy] : []))

const cell = (s: string) => s.replaceAll("|", "\\|").replaceAll("\n", " ")

export const renderPlanMarkdown = (plan: Plan): string => {
  const lines = [
    `# Classic → NEXT migration plan: ${plan.subject.kind} ${plan.subject.id}`,
    "",
    `- migration id: \`${plan.migration_id}\``,
    `- Stack project: \`${plan.stack_project_id}\``,
    `- NEXT team: \`${plan.subject.next_team_id}\``,
    `- source: ${plan.source} (read only; classic is never written)`,
    `- counts: carried ${plan.counts.carried}, copy ${plan.counts.copy}, link ${plan.counts.link}, not-migrated ${plan.counts["not-migrated"]}, needs-decision ${plan.counts["needs-decision"]}`,
    "",
    "| kind | classic id | action | what | NEXT | why | owner rule |",
    "| --- | --- | --- | --- | --- | --- | --- |",
  ]
  for (const e of plan.entries) {
    const next = e.next
      ? Object.entries(e.next)
          .map(([k, v]) => `${k}=${v}`)
          .join(" ")
      : ""
    lines.push(
      `| ${e.kind} | \`${cell(e.classic_id)}\` | ${e.action} | ${cell(e.summary)} | ${cell(next)} | ${cell(e.reason ?? "")} | ${cell(e.personal_reason ?? "")} |`,
    )
  }
  return `${lines.join("\n")}\n`
}

export const renderPlanText = (plan: Plan): string => {
  const out = [
    `plan ${plan.migration_id}: ${plan.subject.kind} ${plan.subject.id} -> NEXT team ${plan.subject.next_team_id}`,
  ]
  for (const e of plan.entries) {
    out.push(`  ${e.action.padEnd(12)} ${e.kind.padEnd(22)} ${e.classic_id}  ${e.summary}`)
    if (e.next)
      out.push(
        `  ${"".padEnd(12)} ${"".padEnd(22)} -> ${Object.entries(e.next)
          .map(([k, v]) => `${k}=${v}`)
          .join(" ")}`,
      )
    if (e.personal_reason) out.push(`  ${"".padEnd(12)} ${"".padEnd(22)} owner: ${e.personal_reason}`)
    if ((e.action === "not-migrated" || e.action === "needs-decision") && e.reason) out.push(`  ${"".padEnd(12)} ${"".padEnd(22)} why: ${e.reason}`)
  }
  out.push(
    `counts: carried ${plan.counts.carried}, copy ${plan.counts.copy}, link ${plan.counts.link}, not-migrated ${plan.counts["not-migrated"]}, needs-decision ${plan.counts["needs-decision"]}`,
  )
  return `${out.join("\n")}\n`
}

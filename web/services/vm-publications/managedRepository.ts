import { and, eq, inArray, isNull, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudOrganizations, cloudVmPublicationVmGuards, cloudVmPublications, cloudVms } from "../../db/schema";
import { assertAccountDeletionUserMutationAllowed } from "../account/deletionLock";
import { allocateVmSlug } from "../vms/vmNaming";
import { managedPublicationHostname, organizationSlugCandidate, validOrganizationSlug } from "./managedHostnames";
import { PublicationConflictError, PublicationNotFoundError, type CloudVmPublicationTarget } from "./repository";

type Tx = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

export type ManagedPublicationInput = {
  readonly ownerUserId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds: readonly string[];
  readonly providerVmId: string;
  readonly organizationName?: string;
  readonly organizationSlug?: string;
  readonly generatedDomain: string;
  readonly port: number;
  readonly accessMode: "personal" | "team" | "public";
  readonly teamId: string | null;
  readonly now: Date;
};

async function reserveOrganization(tx: Tx, input: ManagedPublicationInput, scopeId: string): Promise<string> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`cloud-organization:${scopeId}`}, 0))`);
  const [existing] = await tx.select().from(cloudOrganizations).where(eq(cloudOrganizations.scopeId, scopeId));
  if (existing) {
    if (input.organizationSlug && existing.slug !== input.organizationSlug) {
      throw new PublicationConflictError({ reason: "organization_slug_reserved" });
    }
    return existing.slug;
  }
  if (input.organizationSlug !== undefined && !validOrganizationSlug(input.organizationSlug)) {
    throw new PublicationConflictError({ reason: "invalid_organization_slug" });
  }
  for (let attempt = 0; attempt < 16; attempt++) {
    const slug = input.organizationSlug ?? organizationSlugCandidate(input.organizationName, scopeId, attempt);
    const [claimed] = await tx.insert(cloudOrganizations).values({
      scopeId, slug, ownerUserId: input.ownerUserId, createdAt: input.now,
    }).onConflictDoNothing().returning();
    if (claimed) return claimed.slug;
    if (input.organizationSlug) break;
  }
  throw new PublicationConflictError({ reason: "organization_slug_taken" });
}

async function requireManagedVm(tx: Tx, input: ManagedPublicationInput) {
  const scopeId = input.billingTeamId?.trim() || input.ownerUserId;
  if (scopeId !== input.ownerUserId && !input.teamIds.includes(scopeId)) {
    throw new PublicationNotFoundError({ resource: "vm" });
  }
  // Match VM creation's lock order before taking a VM row lock or assigning a legacy slug.
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${scopeId}, 0))`);
  const [vm] = await tx.select().from(cloudVms).where(and(
    scopeId === input.ownerUserId
      ? sql`(${cloudVms.billingTeamId} = ${scopeId} or (${cloudVms.billingTeamId} is null and ${cloudVms.userId} = ${input.ownerUserId}))`
      : eq(cloudVms.billingTeamId, scopeId),
    eq(cloudVms.provider, "freestyle"),
    eq(cloudVms.providerVmId, input.providerVmId),
    inArray(cloudVms.status, ["running", "paused"]),
  )).for("update").limit(1);
  if (!vm) throw new PublicationNotFoundError({ resource: "vm" });
  const [guard] = await tx.select().from(cloudVmPublicationVmGuards).where(eq(cloudVmPublicationVmGuards.vmId, vm.id));
  if (guard?.teardownStartedAt) throw new PublicationConflictError({ reason: "vm_publication_frozen" });
  return { vm, scopeId };
}

async function ensureVmSlug(tx: Tx, vm: typeof cloudVms.$inferSelect, scopeId: string): Promise<string> {
  if (vm.slug) return vm.slug;
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${scopeId}, 0))`);
  const slug = await allocateVmSlug(async (candidate) => {
    const [row] = await tx.select({ id: cloudVms.id }).from(cloudVms)
      .where(and(
        eq(cloudVms.slug, candidate),
        scopeId === vm.userId
          ? sql`(${cloudVms.billingTeamId} = ${scopeId} or (${cloudVms.billingTeamId} is null and ${cloudVms.userId} = ${vm.userId}))`
          : eq(cloudVms.billingTeamId, scopeId),
        inArray(cloudVms.status, ["provisioning", "running", "paused"]),
      ));
    return !!row;
  });
  await tx.update(cloudVms).set({ slug }).where(eq(cloudVms.id, vm.id));
  return slug;
}

/** VM authorization and hostname reservation commit together. No managed domain row. */
export async function reserveManagedPublication(input: ManagedPublicationInput): Promise<CloudVmPublicationTarget> {
  return cloudDb().transaction(async (tx) => {
    await assertAccountDeletionUserMutationAllowed(tx, input.ownerUserId);
    const { vm, scopeId } = await requireManagedVm(tx, input);
    if (input.accessMode === "team" && input.teamId !== vm.billingTeamId) {
      throw new PublicationConflictError({ reason: "invalid_access_policy" });
    }
    const orgSlug = await reserveOrganization(tx, input, scopeId);
    const vmSlug = await ensureVmSlug(tx, vm, scopeId);
    const hostname = managedPublicationHostname(vmSlug, orgSlug, input.port, input.generatedDomain);
    const [existing] = await tx.select().from(cloudVmPublications).where(and(
      eq(cloudVmPublications.hostname, hostname), isNull(cloudVmPublications.disabledAt),
    ));
    if (existing) {
      if (existing.vmId !== vm.id || existing.port !== input.port) throw new PublicationConflictError({ reason: "hostname_taken" });
      if (existing.state === "disabling") throw new PublicationConflictError({ reason: "publication_not_active" });
      return { publication: existing, vm: { ...vm, slug: vmSlug }, domain: null };
    }
    const [publication] = await tx.insert(cloudVmPublications).values({
      ownerUserId: input.ownerUserId, vmId: vm.id, hostname, domainId: null,
      hostnameClaimedAt: input.now, port: input.port, accessMode: input.accessMode,
      teamId: input.teamId, createdAt: input.now, updatedAt: input.now,
    }).onConflictDoNothing().returning();
    if (!publication) throw new PublicationConflictError({ reason: "hostname_taken" });
    return { publication, vm: { ...vm, slug: vmSlug }, domain: null };
  });
}

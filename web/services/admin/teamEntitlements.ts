// Operator custom Cloud VM deals for teams.
//
// The deal is `clientReadOnlyMetadata.cmuxEntitlementOverride`, which Cloud VM
// entitlements read through team resolution (services/vms/teamEntitlementOverride.ts).
// Who last changed it is kept in `serverMetadata.cmuxAdminEntitlementChange`,
// which end users cannot read. Writes run under the same team mutation lease as
// Team plan grants, so they cannot clobber each other's metadata.

import {
  AccountDeletionMutationBlockedError,
  AccountDeletionUserMutationInProgressError,
} from "../account/deletionLock";
import { billingPlanIdFromMetadata, billingSeatsFromMetadata } from "../billing/teamResolution";
import { grantTeamAdmin } from "../teams/admin";
import { defaultTeamStackApp, withStackDeadline, type TeamStackApp } from "../teams/stack";
import type { ProMetadataJson } from "../billing/pro";
import { teamVmLimits, type TeamVmLimits } from "../vms/entitlements";
import {
  overrideChangesLimits,
  TEAM_ENTITLEMENT_OVERRIDE_METADATA_KEY,
  teamEntitlementOverrideFromMetadata,
  teamEntitlementOverrideFromUnknown,
  type TeamEntitlementOverride,
} from "../vms/teamEntitlementOverride";
import {
  AdminGrantConflictError,
  AdminTeamNotFoundError,
  defaultAdminStackApp,
  defaultWithFreshTeam,
  type AdminStackApp,
  type AdminStackTeam,
  type FreshAdminTeamMutation,
} from "./proGrants";

const CHANGE_METADATA_KEY = "cmuxAdminEntitlementChange";
/** The deal's label and price; server-only so team members cannot read them. */
const DEAL_TERMS_METADATA_KEY = "cmuxEntitlementDealTerms";

export type AdminEntitlementChange = {
  readonly byUserId: string;
  readonly byEmail: string | null;
  readonly at: string;
};

export type AdminTeamEntitlementsView = {
  readonly team: {
    readonly id: string;
    readonly displayName: string;
    readonly planId: string | null;
    readonly seats: number | null;
  };
  readonly override: TeamEntitlementOverride | null;
  readonly defaults: TeamVmLimits;
  readonly effective: TeamVmLimits;
  readonly applies: boolean;
  readonly planHonorsOverride: boolean;
  readonly lastChange: AdminEntitlementChange | null;
};

export async function loadTeamEntitlements(input: {
  readonly teamId: string;
  readonly app?: AdminStackApp;
}): Promise<AdminTeamEntitlementsView> {
  const app = input.app ?? defaultAdminStackApp();
  const team = await app.getTeam(input.teamId);
  if (!team || team.id !== input.teamId) throw new AdminTeamNotFoundError(input.teamId);
  return teamEntitlementsView(team);
}

/** Write or clear (null) the team's deal and record who changed it. */
export async function setTeamEntitlementOverride(input: {
  readonly teamId: string;
  readonly override: TeamEntitlementOverride | null;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly now?: () => Date;
  readonly app?: AdminStackApp;
  readonly withFreshTeam?: FreshAdminTeamMutation;
}): Promise<AdminTeamEntitlementsView> {
  const app = input.app ?? defaultAdminStackApp();
  const now = input.now ?? (() => new Date());
  const withFreshTeam = input.withFreshTeam ?? defaultWithFreshTeam(app);
  try {
    await withFreshTeam(input.teamId, async (team, lease) => {
      await lease.refresh();
      // Members' clients can read clientReadOnlyMetadata, so it carries only
      // the machine limits. The deal's label and price stay in serverMetadata.
      const client = metadataRecord(team.clientReadOnlyMetadata);
      const server = metadataRecord(team.serverMetadata);
      const override = input.override;
      if (override && overrideChangesLimits(override)) {
        client[TEAM_ENTITLEMENT_OVERRIDE_METADATA_KEY] = {
          maxActiveVms: override.maxActiveVms,
          poolVcpus: override.poolVcpus,
          poolMemoryMb: override.poolMemoryMb,
          maxMemoryMb: override.maxMemoryMb,
        };
      } else {
        delete client[TEAM_ENTITLEMENT_OVERRIDE_METADATA_KEY];
      }
      if (override && (override.planLabel !== null || override.monthlyPriceCents !== null)) {
        const terms: AdminDealTerms = { planLabel: override.planLabel, monthlyPriceCents: override.monthlyPriceCents };
        server[DEAL_TERMS_METADATA_KEY] = terms;
      } else {
        delete server[DEAL_TERMS_METADATA_KEY];
      }
      const change: AdminEntitlementChange = {
        byUserId: input.admin.id,
        byEmail: input.admin.primaryEmail ?? null,
        at: now().toISOString(),
      };
      server[CHANGE_METADATA_KEY] = change;
      await team.update({
        clientReadOnlyMetadata: client as ProMetadataJson,
        serverMetadata: server as ProMetadataJson,
      });
    });
  } catch (error) {
    if (
      error instanceof AccountDeletionMutationBlockedError ||
      error instanceof AccountDeletionUserMutationInProgressError
    ) {
      throw new AdminGrantConflictError(input.teamId);
    }
    throw error;
  }
  return loadTeamEntitlements({ teamId: input.teamId, app });
}

export function teamEntitlementsView(team: AdminStackTeam): AdminTeamEntitlementsView {
  const planId = billingPlanIdFromMetadata(team.clientReadOnlyMetadata);
  const seats = billingSeatsFromMetadata(team.clientReadOnlyMetadata);
  const override = teamEntitlementOverrideFromMetadata(team.clientReadOnlyMetadata);
  const limits = teamVmLimits({ planId, seats, override });
  return {
    team: { id: team.id, displayName: team.displayName, planId, seats },
    override: withDealTerms(override, dealTermsFromServerMetadata(team.serverMetadata)),
    defaults: limits.defaults,
    effective: limits.effective,
    applies: limits.applies,
    planHonorsOverride: limits.planHonorsOverride,
    lastChange: changeFromServerMetadata(team.serverMetadata),
  };
}

type AdminDealTerms = {
  readonly planLabel: string | null;
  readonly monthlyPriceCents: number | null;
};

function dealTermsFromServerMetadata(raw: unknown): AdminDealTerms | null {
  const parsed = teamEntitlementOverrideFromUnknown(metadataRecord(raw)[DEAL_TERMS_METADATA_KEY]);
  return parsed ? { planLabel: parsed.planLabel, monthlyPriceCents: parsed.monthlyPriceCents } : null;
}

/** The admin's whole deal: limits from client metadata, label and price from server metadata. */
function withDealTerms(
  limits: TeamEntitlementOverride | null,
  terms: AdminDealTerms | null,
): TeamEntitlementOverride | null {
  if (!limits && !terms) return null;
  return {
    maxActiveVms: limits?.maxActiveVms ?? null,
    poolVcpus: limits?.poolVcpus ?? null,
    poolMemoryMb: limits?.poolMemoryMb ?? null,
    maxMemoryMb: limits?.maxMemoryMb ?? null,
    planLabel: terms?.planLabel ?? null,
    monthlyPriceCents: terms?.monthlyPriceCents ?? null,
  };
}

function changeFromServerMetadata(raw: unknown): AdminEntitlementChange | null {
  const value = metadataRecord(raw)[CHANGE_METADATA_KEY];
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (typeof record.byUserId !== "string" || typeof record.at !== "string") return null;
  return {
    byUserId: record.byUserId,
    byEmail: typeof record.byEmail === "string" ? record.byEmail : null,
    at: record.at,
  };
}

function metadataRecord(raw: unknown): Record<string, unknown> {
  return raw && typeof raw === "object" && !Array.isArray(raw)
    ? { ...(raw as Record<string, unknown>) }
    : {};
}

export class AdminTeamOwnerNotFoundError extends Error {
  constructor(readonly ownerUserId: string) {
    super("team owner not found");
    this.name = "AdminTeamOwnerNotFoundError";
  }
}

/**
 * Create a team for a customer deal, owned by an existing account. The owner
 * gets Stack `team_admin` so they can invite the rest of the team from cmux;
 * a team whose admin grant fails is deleted again. Unlike the self-serve
 * create, the owner's selected team is left alone.
 */
export async function createTeamForCustomer(input: {
  readonly displayName: string;
  readonly ownerUserId: string;
  readonly stack?: TeamStackApp;
  /** Test seam for the Stack request deadline. */
  readonly withDeadline?: <T>(operation: () => Promise<T>) => Promise<T>;
  /**
   * Keeps work alive after the response (the route passes Next's `after`, so
   * Vercel does not freeze the function before a late cleanup runs).
   */
  readonly defer?: (task: () => Promise<void>) => void;
}): Promise<{ readonly id: string; readonly displayName: string }> {
  const stack = input.stack ?? defaultTeamStackApp();
  const withDeadline = input.withDeadline ?? withStackDeadline;
  const owner = await withDeadline(() => stack.getUser(input.ownerUserId));
  if (!owner) throw new AdminTeamOwnerNotFoundError(input.ownerUserId);
  const creating = stack.createTeam({
    displayName: input.displayName,
    creatorUserId: input.ownerUserId,
  });
  let team: Awaited<typeof creating>;
  try {
    team = await withDeadline(() => creating);
  } catch (error) {
    // The deadline stops waiting but cannot cancel the request. If Stack
    // commits the team anyway, nobody holds its id, so delete it here when it
    // arrives (best effort, while this process lives).
    const cleanup = () => creating.then(
      (late) => withDeadline(() => late.delete()).catch(() => {
        console.error("admin team create late cleanup failed", { teamId: late.id });
      }),
      () => undefined,
    );
    if (input.defer) input.defer(cleanup);
    else void cleanup();
    throw error;
  }
  try {
    await withDeadline(() => grantTeamAdmin(stack, input.ownerUserId, team));
  } catch (error) {
    await withDeadline(() => team.delete()).catch(() => {
      console.error("admin team create rollback failed", { teamId: team.id });
    });
    throw error;
  }
  return { id: team.id, displayName: team.displayName };
}

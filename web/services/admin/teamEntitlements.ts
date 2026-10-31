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
  TEAM_ENTITLEMENT_OVERRIDE_METADATA_KEY,
  teamEntitlementOverrideFromMetadata,
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
      const client = metadataRecord(team.clientReadOnlyMetadata);
      if (input.override === null) {
        delete client[TEAM_ENTITLEMENT_OVERRIDE_METADATA_KEY];
      } else {
        client[TEAM_ENTITLEMENT_OVERRIDE_METADATA_KEY] = { ...input.override };
      }
      const server = metadataRecord(team.serverMetadata);
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
    override,
    defaults: limits.defaults,
    effective: limits.effective,
    applies: limits.applies,
    planHonorsOverride: limits.planHonorsOverride,
    lastChange: changeFromServerMetadata(team.serverMetadata),
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
}): Promise<{ readonly id: string; readonly displayName: string }> {
  const stack = input.stack ?? defaultTeamStackApp();
  const owner = await withStackDeadline(() => stack.getUser(input.ownerUserId));
  if (!owner) throw new AdminTeamOwnerNotFoundError(input.ownerUserId);
  const team = await withStackDeadline(() => stack.createTeam({
    displayName: input.displayName,
    creatorUserId: input.ownerUserId,
  }));
  try {
    await withStackDeadline(() => grantTeamAdmin(stack, input.ownerUserId, team));
  } catch (error) {
    await withStackDeadline(() => team.delete()).catch(() => {
      console.error("admin team create rollback failed", { teamId: team.id });
    });
    throw error;
  }
  return { id: team.id, displayName: team.displayName };
}

import { eq } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { subrouterTenants } from "../../db/schema";

type LegacyTenantCutover = {
  readonly hostedReadyAt: Date | null;
};

type LegacyTenantCutoverLookup = (
  teamId: string,
) => Promise<LegacyTenantCutover | undefined>;

export async function hostedSubrouterCutoverReadyForTeam(
  teamId: string,
  lookup: LegacyTenantCutoverLookup = loadLegacyTenantCutover,
): Promise<boolean> {
  const legacyMapping = await lookup(teamId);
  if (!legacyMapping) return true;
  return legacyMapping.hostedReadyAt instanceof Date &&
    !Number.isNaN(legacyMapping.hostedReadyAt.getTime());
}

async function loadLegacyTenantCutover(
  teamId: string,
): Promise<LegacyTenantCutover | undefined> {
  const rows = await cloudDb()
    .select({ hostedReadyAt: subrouterTenants.hostedReadyAt })
    .from(subrouterTenants)
    .where(eq(subrouterTenants.teamId, teamId))
    .limit(1);
  return rows[0];
}

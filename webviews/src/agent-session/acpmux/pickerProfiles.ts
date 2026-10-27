// The installed launch configurations a harness's Profile submenu lists. buildPickerCatalog
// folds profiles of one family into one harness entry; these restore those configurations without
// presenting internal launchers as signed-in accounts. Account uses route identities separately.
import { agentKey } from "../shared/agentKey";
import type { AcpmuxSnapshot } from "./model";

type Entry = AcpmuxSnapshot["catalog"][number];

/// One installed profile of a harness: its acpmux id and the name the menu shows.
export type PickerProfile = { id: string; name: string; unavailable?: string };

/// acpmux's family for a profile, as buildPickerCatalog joins it to a catalog harness.
const familyOf = (entry: Entry) => entry.family ?? agentKey(entry.id) ?? entry.id;

/// Every global profile of `acpmuxHarness`'s family, in acpmux's order (that profile among them);
/// none when acpmux does not list it. A folder's profiles stay out: the picker lists them on their own.
export function familyProfiles(catalog: readonly Entry[], acpmuxHarness: string | null | undefined): PickerProfile[] {
  const chosen = catalog.find((entry) => entry.id === acpmuxHarness && !entry.folder);
  if (!chosen) return [];
  const family = familyOf(chosen);
  return catalog
    .filter((entry) => !entry.folder && entry.pickable !== false && familyOf(entry) === family)
    .map((entry) => ({
      id: entry.id,
      // A profile named only by its id is shown by it ("claude-sr"): its brand's name would read as
      // the harness's own profile.
      name: entry.name && entry.name !== entry.id ? entry.name : entry.id,
      ...(entry.unavailable && !entry.probeFailed ? { unavailable: entry.unavailable } : {}),
    }));
}

/// `familyProfiles` for each harness of the picker's catalog, by the acpmux id its entry carries.
export function catalogProfiles(
  catalog: readonly Entry[],
  harnesses: readonly { acpmuxHarness: string | null }[],
): Record<string, PickerProfile[]> {
  const out: Record<string, PickerProfile[]> = {};
  for (const { acpmuxHarness } of harnesses)
    if (acpmuxHarness) out[acpmuxHarness] = familyProfiles(catalog, acpmuxHarness);
  return out;
}

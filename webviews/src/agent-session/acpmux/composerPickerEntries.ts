import type { AcpmuxSnapshot } from "./model";
import type { PickerCatalog } from "./modelCatalogData";
import { pickerFaceHarness } from "./modelPickerModel";
import type { ModelPickerProps } from "./modelPickerLayout";

/** The composer's existing catalog projection, shared with its pre-send health notice. */
/** `listed`: acpmux has answered with its harnesses. Before it has, a catalog harness is no
 *  missing one: its bundled models are the menu's rows, pickable by the catalog id, which is
 *  acpmux's own (Leo 2026-11-08: "we know what the models are"). Only an answered list says
 *  which harness is not installed. */
export function composerPickerEntries(
  snapshot: AcpmuxSnapshot,
  pickerCatalog?: PickerCatalog,
  listed = true,
): ModelPickerProps["catalog"] {
  const summary = snapshot.summary;
  return pickerCatalog
    ? [
        ...pickerCatalog.harnesses
          .filter(
            (entry) =>
              !entry.unavailable || entry.probeFailed || (entry.acpmuxHarness ?? entry.id) === summary?.harness,
          )
          .map((entry) => ({
            id: entry.acpmuxHarness ?? entry.id,
            name: entry.name,
            models: entry.models,
            ...(entry.family ? { family: entry.family } : {}),
            ...(entry.unavailable ? { unavailable: entry.unavailable } : {}),
            pickable: entry.pickable && (entry.acpmuxHarness !== null || !listed),
            // The picker lists it anyway, with its Install… row (Leo 2026-10-26: "show all harnesses").
            ...(listed && !entry.installed && entry.pickable ? { notInstalled: true as const } : {}),
            ...(entry.topModels ? { top: entry.topModels } : {}),
          })),
        // The chat folder's own profiles are acpmux's alone; the model catalog never lists them.
        ...snapshot.catalog.filter((entry) => entry.folder),
      ]
    : snapshot.catalog;
}

/** Read the chip's harness without selecting one or changing the daemon's default. */
export function composerHealthHarness(
  snapshot: AcpmuxSnapshot,
  pickerCatalog: PickerCatalog,
  listed = true,
): string | undefined {
  if (snapshot.summary?.harness || snapshot.sessionId) return snapshot.summary?.harness;
  const entries = composerPickerEntries(snapshot, pickerCatalog, listed);
  return pickerFaceHarness(entries) ?? entries[0]?.id;
}

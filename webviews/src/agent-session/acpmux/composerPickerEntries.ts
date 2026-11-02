import type { AcpmuxSnapshot } from "./model";
import type { PickerCatalog } from "./modelCatalogData";
import { pickerFaceHarness } from "./ModelPicker";
import type { ModelPickerProps } from "./modelPickerLayout";

/** The composer's existing catalog projection, shared with its pre-send health notice. */
export function composerPickerEntries(
  snapshot: AcpmuxSnapshot,
  pickerCatalog?: PickerCatalog,
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
            pickable: entry.pickable && entry.acpmuxHarness !== null,
            // The picker lists it anyway, with its Install… row (Leo 2026-10-26: "show all harnesses").
            ...(!entry.installed && entry.pickable ? { notInstalled: true as const } : {}),
            ...(entry.topModels ? { top: entry.topModels } : {}),
          })),
        // The chat folder's own profiles are acpmux's alone; the model catalog never lists them.
        ...snapshot.catalog.filter((entry) => entry.folder),
      ]
    : snapshot.catalog;
}

/** Read the chip's harness without selecting one or changing the daemon's default. */
export function composerHealthHarness(snapshot: AcpmuxSnapshot, pickerCatalog: PickerCatalog): string | undefined {
  if (snapshot.summary?.harness || snapshot.sessionId) return snapshot.summary?.harness;
  const entries = composerPickerEntries(snapshot, pickerCatalog);
  return pickerFaceHarness(entries) ?? entries[0]?.id;
}

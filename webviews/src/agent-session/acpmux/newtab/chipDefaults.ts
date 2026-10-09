// The New Tab chip before a pick (cx-e2aa decision, chief 2026-10-09): it names the shown agent's
// default model from the model catalog, never a bare "Model" or "Default".
import { isDefaultChoice } from "../defaultChoice";
import type { AcpmuxSnapshot } from "../model";
import type { PickerCatalog } from "../modelCatalogData";

/// `snapshot` with the catalog's default model for its agent when it names none (or only the
/// agent's own "default"); otherwise unchanged.
export function newTabChipSnapshot(snapshot: AcpmuxSnapshot, catalog: PickerCatalog | undefined): AcpmuxSnapshot {
  const summary = snapshot.summary;
  const harness = summary?.harness;
  if (!summary || !harness || (summary.model && !isDefaultChoice({ id: summary.model }))) return snapshot;
  const model = catalog?.harnesses.find((entry) => (entry.acpmuxHarness ?? entry.id) === harness)?.defaultModel;
  return model ? { ...snapshot, summary: { ...summary, model, confirmedModel: model } } : snapshot;
}

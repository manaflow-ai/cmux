// The New Tab chip before a pick (cx-e2aa decision, chief 2026-10-09): it names the shown agent's
// default model from the model catalog, never a bare "Model" or "Default".
import { isDefaultChoice } from "../defaultChoice";
import type { AcpmuxSnapshot } from "../model";
import type { PickerCatalog } from "../modelCatalogData";

/// `snapshot` with the catalog's default model for its agent when it names none (or only the
/// agent's own "default"), listed in the agent's session catalog with the catalog's name so the
/// chip reads it ("Opus 5.5"); otherwise unchanged.
export function newTabChipSnapshot(snapshot: AcpmuxSnapshot, catalog: PickerCatalog | undefined): AcpmuxSnapshot {
  const summary = snapshot.summary;
  const harness = summary?.harness;
  if (!summary || !harness || (summary.model && !isDefaultChoice({ id: summary.model }))) return snapshot;
  const entry = catalog?.harnesses.find((candidate) => (candidate.acpmuxHarness ?? candidate.id) === harness);
  const model = entry?.defaultModel;
  if (!model) return snapshot;
  const name = entry.models.find((choice) => choice.id === model)?.name ?? model;
  const sessionCatalog = snapshot.catalog.map((agent) =>
    agent.id === harness && !agent.models.some((choice) => choice.id === model)
      ? { ...agent, models: [...agent.models, { id: model, name }] }
      : agent,
  );
  return { ...snapshot, catalog: sessionCatalog, summary: { ...summary, model, confirmedModel: model } };
}

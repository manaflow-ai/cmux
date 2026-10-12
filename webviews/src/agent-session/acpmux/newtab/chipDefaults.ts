// The New Tab chip before a pick (cx-e2aa decision, chief 2026-10-09): it names the shown agent's
// default model from the model catalog, never a bare "Model" or "Default".
import { isDefaultChoice } from "../defaultChoice";
import { defaultModel } from "../harnessSwitch";
import { lastPick } from "../lastPick";
import type { AcpmuxSnapshot } from "../model";
import type { PickerCatalog } from "../modelCatalogData";
import { defaultHarness, type ScreenAgent } from "./screenModel";

/// The New Tab page's agent and model before a pick: the chip's pick (drawn into the summary), else
/// the harness and model picked last in `folder` or anywhere (lastPick.ts, Leo 2026-10-11), else
/// the remembered agent or the first installed with its default model.
export function newTabStart(
  snapshot: AcpmuxSnapshot,
  agents: readonly ScreenAgent[],
  lastAgent: string | undefined,
  folder: string | undefined,
): { harness: string | undefined; snapshot: AcpmuxSnapshot } {
  if (snapshot.summary?.harness) return { harness: snapshot.summary.harness, snapshot };
  const picked = lastPick(folder)?.harness;
  const harness = picked && agents.some((agent) => agent.id === picked) ? picked : defaultHarness(agents, lastAgent);
  if (!harness) return { harness, snapshot };
  return {
    harness,
    snapshot: {
      ...snapshot,
      summary: {
        ...snapshot.summary,
        sessionId: snapshot.summary?.sessionId ?? "",
        turnCount: snapshot.summary?.turnCount ?? 0,
        harness,
        // The agent's model, named on the chip (its own "default" when none is known yet).
        model: defaultModel(harness, snapshot.catalog, undefined, folder) ?? "default",
      },
    },
  };
}

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

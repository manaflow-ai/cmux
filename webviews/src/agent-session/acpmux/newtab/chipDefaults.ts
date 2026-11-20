// The New Tab chip before a pick (cx-e2aa decision, chief 2026-10-09): it names the shown agent's
// default model from the model catalog, never a bare "Model" or "Default".
import { useMemo } from "react";
import { isDefaultChoice } from "../defaultChoice";
import { defaultModel } from "../harnessSwitch";
import { type LastPick, lastPick } from "../lastPick";
import type { AcpmuxSnapshot } from "../model";
import { buildPickerCatalog, type PickerCatalog } from "../modelCatalogData";
import { useModelCatalogState } from "../modelCatalogHost";
import { defaultHarness, type ScreenAgent } from "./screenModel";

/// The New Tab page's agent and model before a pick: the chip's pick (drawn into the summary), else
/// the harness and model picked last in `folder` or anywhere (lastPick.ts, Leo 2026-10-11), else
/// the remembered agent or the first installed with its default model.
export function newTabStart(
  snapshot: AcpmuxSnapshot,
  agents: readonly ScreenAgent[],
  lastAgent: string | undefined,
  folder: string | undefined,
  remembered: LastPick | undefined = lastPick(folder),
  /// acpmux answered with its harnesses (`useHarnessesListed`), even with none.
  harnessesListed = false,
): { harness: string | undefined; snapshot: AcpmuxSnapshot } {
  if (snapshot.summary?.harness) return { harness: snapshot.summary.harness, snapshot };
  // The last pick's harness while it is here and its launcher runs (a failed model probe alone
  // does not count): a harness that could not start does not keep taking New Tabs.
  // Before acpmux lists its harnesses (the launch's first page keeps no catalog), the app's copy of
  // the last pick stands: it started a chat when it was picked. Its harness and model are then named
  // from the first frame, and acpmux's list confirms or replaces them (Lucas 2026-10-24: the harness
  // and the effort popped in a moment after the page showed).
  const picked = remembered?.harness;
  // An empty list acpmux answered is a listing too: the remembered harness is gone (Add harness shows).
  const listed = harnessesListed || snapshot.catalog.some((candidate) => !candidate.folder);
  const entry = snapshot.catalog.find((candidate) => candidate.id === picked);
  const runs = entry !== undefined && (!entry.unavailable || entry.probeFailed === true);
  const kept = picked !== undefined && !listed;
  const harness =
    picked && ((runs && agents.some((agent) => agent.id === picked)) || kept)
      ? picked
      : defaultHarness(agents, lastAgent);
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
        model:
          (kept && harness === picked && remembered && !isDefaultChoice({ id: remembered.model })
            ? remembered.model
            : undefined) ??
          defaultModel(harness, snapshot.catalog, undefined, folder) ??
          "default",
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

/// The model the New Tab chip names for `snapshot` (newTabChipSnapshot over the model catalog), the
/// one Return asks the agent on: else the chat started on the agent's own default, which can be
/// another model than the chip promised (cx-sljrg). Undefined when the chip names only "default".
export function useNewTabChipModel(snapshot: AcpmuxSnapshot): string | undefined {
  const { catalog, user, provisional } = useModelCatalogState();
  const harness = snapshot.summary?.harness;
  const picker = useMemo(
    () => buildPickerCatalog({ catalog, user, acpmux: snapshot.catalog, session: { harness }, provisional }),
    [catalog, user, snapshot.catalog, harness, provisional],
  );
  const model = newTabChipSnapshot(snapshot, picker).summary?.model;
  return model && !isDefaultChoice({ id: model }) ? model : undefined;
}

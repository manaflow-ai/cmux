// The New Tab chip before a pick (cx-e2aa decision, chief 2026-10-09): it names the shown agent's
// default model from the model catalog, never a bare "Model" or "Default".
import { useMemo } from "react";
import { aliasNamedAsRelease, shortModelName } from "../composerPickerModel";
import { isDefaultChoice, loadResolvedAlias, modelIdName } from "../defaultChoice";
import { defaultModel } from "../harnessSwitch";
import { useT, type Translate } from "../i18n";
import { type LastPick, lastPick } from "../lastPick";
import type { AcpmuxSnapshot } from "../model";
import { buildPickerCatalog, type PickerCatalog } from "../modelCatalogData";
import { useModelCatalogState } from "../modelCatalogHost";
import { defaultHarness, type ScreenAgent } from "./screenModel";

/// The New Tab page's agent and model before a pick: the chip's pick (drawn into the summary), else
/// the harness and model picked last in `folder` or anywhere (lastPick.ts, Leo 2026-10-11), else
/// the remembered agent or the first installed with its default model; none while acpmux names no
/// default (listedNoDefault).
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
      : listedNoDefault(snapshot.catalog) && !agents.some((agent) => agent.id === lastAgent)
        ? undefined
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

/// acpmux listed its harnesses and named none the default: a Mac with only the built-in Chief and
/// UniiChat (default_harness.rs). New Tab then starts on no agent, so its Add harness setup shows
/// instead of a first tab signed out of UniiChat (onboarding probe 2026-11-22).
export function listedNoDefault(catalog: AcpmuxSnapshot["catalog"]): boolean {
  const listed = catalog.filter((entry) => !entry.folder);
  return listed.length > 0 && listed.every((entry) => entry.noDefault === true);
}

/// `snapshot` with the catalog's default model for its agent when it names none (or only the
/// agent's own "default"), listed in the agent's session catalog with the catalog's name so the
/// chip reads it ("Opus 5.5"); otherwise unchanged.
/// `newTabStart`, kept while its inputs are: the chips take its snapshot, and a new one each render rendered every
/// chip (and their menus) again on each key in the New Tab field (typing lag, Lawrence 2026-11-19).
export function useNewTabStart(
  snapshot: AcpmuxSnapshot,
  agents: readonly ScreenAgent[],
  lastAgent: string | undefined,
  folder: string | undefined,
  remembered: LastPick | undefined,
  harnessesListed: boolean,
): { harness: string | undefined; snapshot: AcpmuxSnapshot } {
  return useMemo(
    () => newTabStart(snapshot, agents, lastAgent, folder, remembered, harnessesListed),
    [snapshot, agents, lastAgent, folder, remembered, harnessesListed],
  );
}

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
export function useNewTabChipModel(snapshot: AcpmuxSnapshot): { id: string; name: string } | undefined {
  const t = useT();
  const { catalog, user, provisional } = useModelCatalogState();
  const harness = snapshot.summary?.harness;
  const picker = useMemo(
    () => buildPickerCatalog({ catalog, user, acpmux: snapshot.catalog, session: { harness }, provisional }),
    [catalog, user, snapshot.catalog, harness, provisional],
  );
  const id = newTabChipSnapshot(snapshot, picker).summary?.model;
  if (!id || isDefaultChoice({ id })) return undefined;
  return { id, name: newTabModelName(id, harness, snapshot, picker, t) };
}

function newTabModelName(
  id: string,
  harness: string | undefined,
  snapshot: AcpmuxSnapshot,
  picker: PickerCatalog,
  t: Translate,
): string {
  const entry = picker.harnesses.find((candidate) => (candidate.acpmuxHarness ?? candidate.id) === harness);
  const model = entry?.models.find((model) => model.id === id || model.release === id);
  const sessionName = snapshot.catalog
    .find((agent) => agent.id === harness)
    ?.models.find((model) => model.id === id)?.name;
  const baseName = [model?.name, sessionName].find((name) => name && name !== id) ?? modelIdName(id, t);
  const release = harness && loadResolvedAlias(harness, id);
  const releaseName = release
    ? (picker.harnesses.flatMap((agent) => agent.models).find((model) => model.id === release)?.name ??
      modelIdName(release, t))
    : undefined;
  const name = releaseName ? aliasNamedAsRelease(baseName, releaseName) : baseName;
  return shortModelName(name, model?.shortName, entry?.name) ?? name;
}

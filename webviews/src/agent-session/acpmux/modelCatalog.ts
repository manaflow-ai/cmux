import { harnessRefusal, normalizeCatalog } from "./direct";
import type { AcpmuxSnapshot } from "./model";

// The composer's model catalog. acpmux keeps its harness list (`_acpmux/harnesses`: names,
// launchers, availability) apart from the models it probed from each harness
// (`_acpmux/models`), so the catalog is the one filled from the other.

type Catalog = AcpmuxSnapshot["catalog"];
type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// `names` (_acpmux/harnesses) with each harness's models from `probed` (_acpmux/models);
/// harnesses only `probed` names (a peer's) are added. A list that already carries models
/// (the mock daemon) keeps them. A harness acpmux will not start keeps the reason as
/// `unavailable`: its launcher check (`unavailable` on the _acpmux/harnesses entry) first, else its
/// failed model probe (`probeError`, on either list's entry).
export function mergeModelCatalog(names: unknown, probed: unknown): Catalog {
  const catalog = normalizeCatalog(names);
  const entries = (probed as { harnesses?: unknown } | undefined)?.harnesses;
  if (!Array.isArray(entries)) return catalog;
  const byHarness = new Map<string, Catalog[number]["models"]>();
  const refused = new Map<string, string>();
  for (const entry of entries as { harness?: unknown; models?: unknown; probeError?: unknown }[]) {
    const reason = harnessRefusal({ probeError: entry?.probeError });
    if (typeof entry?.harness === "string" && reason) refused.set(entry.harness, reason);
    if (typeof entry?.harness !== "string" || !Array.isArray(entry.models)) continue;
    byHarness.set(
      entry.harness,
      (entry.models as { id?: unknown; modelId?: unknown; name?: unknown; unavailable?: unknown }[]).map((model) => ({
        id: String(model.id ?? model.modelId),
        name: typeof model.name === "string" ? model.name : undefined,
        ...(typeof model.unavailable === "string" ? { unavailable: model.unavailable } : {}),
      })),
    );
  }
  const withReason = (harness: Catalog[number]): Catalog[number] => {
    const reason = harness.unavailable ?? refused.get(harness.id);
    return reason ? { ...harness, unavailable: reason } : harness;
  };
  const merged = catalog.map((harness) =>
    withReason(harness.models.length > 0 ? harness : { ...harness, models: byHarness.get(harness.id) ?? [] }),
  );
  for (const [id, models] of byHarness) {
    if (!merged.some((harness) => harness.id === id)) merged.push(withReason({ id, name: id, models }));
  }
  return merged;
}

/// The models of `models` the picker offers: those acpmux will run, and `current` whatever it is.
export function offeredModels<T extends { id: string; unavailable?: string }>(models: T[], current?: string): T[] {
  return models.filter((model) => !model.unavailable || model.id === current);
}

/// The models offered for the session: its harness's catalog entry, else the choices of the
/// session's own model option (an agent reports them before acpmux's probe finishes).
export function sessionModels(
  catalog: Catalog,
  summary: Pick<Summary, "harness" | "model" | "configOptions"> | undefined,
): { id: string; name: string }[] {
  const listed = catalog.find((harness) => harness.id === summary?.harness)?.models ?? [];
  if (listed.length > 0)
    return offeredModels(listed, summary?.model).map((model) => ({ id: model.id, name: model.name || model.id }));
  const option = summary?.configOptions?.find(
    (candidate) => candidate.category === "model" || candidate.id === "model",
  );
  return (option?.options ?? []).map((choice) => ({ id: choice.value, name: choice.name || choice.value }));
}

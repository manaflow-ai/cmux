import { catalogModel, harnessRefusal, normalizeCatalog } from "./direct";
import type { AcpmuxSnapshot } from "./model";

// The composer's model catalog. acpmux keeps its harness list (`_acpmux/harnesses`: names,
// launchers, availability) apart from the models it probed from each harness
// (`_acpmux/models`), so the catalog is the one filled from the other.

type Catalog = AcpmuxSnapshot["catalog"];
type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// `names` (_acpmux/harnesses) with each harness's models from `probed` (_acpmux/models);
/// the local harness list alone determines what can start here. Peer model probes never add
/// harnesses or replace local models. A list that already carries models
/// (the mock daemon) keeps them. A harness acpmux will not start keeps the reason as
/// `unavailable`: its launcher check (`unavailable` on the _acpmux/harnesses entry) first, else its
/// failed model probe (`probeError`, on either list's entry).
export function mergeModelCatalog(names: unknown, probed: unknown): Catalog {
  const catalog = normalizeCatalog(names);
  const entries = (probed as { harnesses?: unknown } | undefined)?.harnesses;
  if (!Array.isArray(entries)) return catalog;
  const byHarness = new Map<string, Catalog[number]["models"]>();
  const refused = new Map<string, string>();
  const topModels = new Map<string, string[]>();
  for (const entry of entries as {
    harness?: unknown;
    models?: unknown;
    topModels?: unknown;
    probeError?: unknown;
    peer?: unknown;
  }[]) {
    if (entry?.peer != null && entry.peer !== "") continue;
    const reason = harnessRefusal({ probeError: entry?.probeError });
    if (typeof entry?.harness === "string" && reason) refused.set(entry.harness, reason);
    if (typeof entry?.harness !== "string" || !Array.isArray(entry.models)) continue;
    if (Array.isArray(entry.topModels) && entry.topModels.every((id) => typeof id === "string"))
      topModels.set(entry.harness, entry.topModels as string[]);
    byHarness.set(
      entry.harness,
      (entry.models as unknown[]).map((model) => catalogModel(model)),
    );
  }
  const withReason = (harness: Catalog[number]): Catalog[number] => {
    if (harness.unavailable) return harness;
    const reason = refused.get(harness.id);
    return reason ? { ...harness, unavailable: reason, probeFailed: true } : harness;
  };
  const merged = catalog.map((harness) =>
    withReason({
      ...harness,
      models: harness.models.length > 0 ? harness.models : (byHarness.get(harness.id) ?? []),
      ...(topModels.has(harness.id) ? { topModels: topModels.get(harness.id) } : {}),
    }),
  );
  return merged;
}

/// The models offered for the session: its harness's catalog entry, else the choices of the
/// session's own model option (an agent reports them before acpmux's probe finishes).
export function sessionModels(
  catalog: Catalog,
  summary: Pick<Summary, "harness" | "configOptions"> | undefined,
): { id: string; name: string }[] {
  const listed = catalog.find((harness) => harness.id === summary?.harness)?.models ?? [];
  if (listed.length > 0) return listed.map((model) => ({ id: model.id, name: modelLabel(model) }));
  const option = summary?.configOptions?.find(
    (candidate) => candidate.category === "model" || candidate.id === "model",
  );
  return (option?.options ?? []).map((choice) => ({ id: choice.value, name: choice.name || choice.value }));
}

/// A model's label; one acpmux will not run says so, with the start of the reason.
export function modelLabel(model: { id: string; name?: string; unavailable?: string }): string {
  const name = model.name || model.id;
  if (!model.unavailable) return name;
  const reason = model.unavailable.length > 60 ? `${model.unavailable.slice(0, 59)}…` : model.unavailable;
  return `${name} · unavailable: ${reason}`;
}

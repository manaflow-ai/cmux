import { normalizeCatalog } from "./direct";
import type { AcpmuxSnapshot } from "./model";

// The composer's model catalog. acpmux keeps its harness list (`_acpmux/harnesses`: names,
// launchers, availability) apart from the models it probed from each harness
// (`_acpmux/models`), so the catalog is the one filled from the other.

type Catalog = AcpmuxSnapshot["catalog"];
type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// `names` (_acpmux/harnesses) with each harness's models from `probed` (_acpmux/models);
/// harnesses only `probed` names (a peer's) are added. A list that already carries models
/// (the mock daemon) keeps them.
export function mergeModelCatalog(names: unknown, probed: unknown): Catalog {
  const catalog = normalizeCatalog(names);
  const entries = (probed as { harnesses?: unknown } | undefined)?.harnesses;
  if (!Array.isArray(entries)) return catalog;
  const byHarness = new Map<string, Catalog[number]["models"]>();
  for (const entry of entries as { harness?: unknown; models?: unknown }[]) {
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
  const merged = catalog.map((harness) =>
    harness.models.length > 0 ? harness : { ...harness, models: byHarness.get(harness.id) ?? [] },
  );
  for (const [id, models] of byHarness) {
    if (!merged.some((harness) => harness.id === id)) merged.push({ id, name: id, models });
  }
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

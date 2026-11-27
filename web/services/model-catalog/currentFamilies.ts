import currentFamilies from "../../data/model-catalog/current-families.json";
import type { HarnessModel, ModelCatalog } from "./types";

/** Keep offline catalogs current when the feed lags a known release. These identity-only
 * fallbacks never invent capabilities, replace feed metadata, or change a harness default.
 * The picker uses the same data for family order; live harness menus remain authoritative. */
export function withCurrentFamilyFallbacks(catalog: ModelCatalog, generatedAt = new Date()): ModelCatalog {
  const families: Record<string, HarnessModel[]> = currentFamilies;
  const updated = {
    ...catalog,
    harnesses: catalog.harnesses.map((harness) => {
      const current = families[harness.id];
      if (!current || harness.modelSource !== "catalog") return harness;
      const ids = new Set(current.map((model) => model.id));
      return {
        ...harness,
        models: [
          ...current.map(
            (model) => harness.models.find((existing) => existing.id === model.id) ?? { ...model },
          ),
          ...harness.models.filter((model) => !ids.has(model.id)),
        ],
      };
    }),
  };
  if (JSON.stringify(updated.harnesses) === JSON.stringify(catalog.harnesses)) return catalog;
  // Stored catalogs win on equal timestamps. A content change must supersede the old bundle.
  return {
    ...updated,
    generatedAt: new Date(Math.max(generatedAt.getTime(), Date.parse(catalog.generatedAt) + 1)).toISOString(),
  };
}

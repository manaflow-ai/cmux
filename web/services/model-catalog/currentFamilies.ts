import currentFamilies from "../../data/model-catalog/current-families.json";
import type { HarnessModel, ModelCatalog } from "./types";

/** Keep offline catalogs current when the feed lags a known release. These identity-only
 * fallbacks never invent capabilities, replace feed metadata, or change a harness default.
 * The picker uses the same data for family order; live harness menus remain authoritative. */
export function withCurrentFamilyFallbacks(catalog: ModelCatalog): ModelCatalog {
  const families: Record<string, HarnessModel[]> = currentFamilies;
  return {
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
}

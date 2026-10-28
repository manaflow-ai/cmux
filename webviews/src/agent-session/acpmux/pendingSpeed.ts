import type { AcpmuxCatalogModel, AcpmuxSnapshot } from "./model";
import { harnessProfiles } from "./harnessProfiles";

/** A new chat uses the model's advertised tiers before it has session options of its own. */
export function pendingSpeed(snapshot: AcpmuxSnapshot, advertised?: Pick<AcpmuxCatalogModel, "fast" | "serviceTiers">) {
  const summary = snapshot.summary;
  if (!summary?.harness || (summary.sessionId && !snapshot.switching)) return undefined;
  const model = snapshot.catalog
    .find((entry) => entry.id === summary.harness)
    ?.models.find((entry) => entry.id === summary.model);
  const tiers = (model?.serviceTiers ?? advertised?.serviceTiers)?.filter(
    (tier) => (typeof tier === "string" ? tier : tier.id) !== "default",
  );
  if (tiers?.length)
    return {
      id: "fast-mode",
      currentValue: "default",
      options: [
        { value: "default" },
        ...tiers.map((tier) =>
          typeof tier === "string"
            ? { value: tier, name: tier }
            : { value: tier.id, name: tier.name, description: tier.description },
        ),
      ],
    };
  const profile = harnessProfiles.get(summary.harness);
  const profileOption =
    profile && profile.model === summary.model
      ? profile.configOptions?.find((option) => option.id === "fast-mode")
      : undefined;
  if (profileOption) return profileOption;
  // A bundled model catalog can promise Fast before a new session has reported its config
  // options. Keep that control in the New Tab model menu instead of waiting for the first frame.
  if (model?.fast === true || advertised?.fast === true)
    return {
      id: "fast-mode",
      currentValue: "off",
      options: [{ value: "off" }, { value: "on" }],
    };
  return undefined;
}

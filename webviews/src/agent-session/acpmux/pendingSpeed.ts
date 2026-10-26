import type { AcpmuxSnapshot } from "./model";
import { harnessProfiles } from "./harnessProfiles";

/** A new chat uses the model's advertised tiers before it has session options of its own. */
export function pendingSpeed(snapshot: AcpmuxSnapshot) {
  const summary = snapshot.summary;
  if (!summary?.harness || (summary.sessionId && !snapshot.switching)) return undefined;
  const model = snapshot.catalog
    .find((entry) => entry.id === summary.harness)
    ?.models.find((entry) => entry.id === summary.model);
  const tiers = model?.serviceTiers?.filter((tier) => (typeof tier === "string" ? tier : tier.id) !== "default");
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
  return profile && profile.model === summary.model
    ? profile.configOptions?.find((option) => option.id === "fast-mode")
    : undefined;
}

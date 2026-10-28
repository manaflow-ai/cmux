// The harness owns its default menu. Preserve that list and its order when it reports one;
// only a harness without a menu report falls back to its newest available model per family.
// Provider duplicates have already been grouped. Current/recent selections never promote rows.
type Model = {
  id: string;
  name: string;
  family?: string;
  release?: string;
  unavailable?: string;
  offers?: readonly { id: string; release?: string; unavailable?: string }[];
};

/** Unknown family names stay data: remove version tokens, not a maintained list of model names. */
function familyKey(model: Model): string {
  const parts = (model.release ?? model.id).split("/");
  const vendor = parts.length > 1 ? parts.at(-2) : "";
  const inferred = (parts.at(-1) ?? model.name)
    .replace(/\[[^\]]*\]/g, "")
    .replace(/(?:^|[-_])v?\d+(?:[.-]\d+)*(?=[-_]|$)/gi, "-")
    .replace(/\d+(?:\.\d+)*/g, "")
    .replace(/[-_]+/g, "-")
    .replace(/^-|-$/g, "");
  return `${vendor}\u0000${model.family ?? inferred}`.toLowerCase();
}

const version = (model: Model) =>
  (
    (model.name.split(" · ")[0] ?? "").match(/\d+(?:\.\d+)*/)?.[0]?.split(".") ??
    (model.release ?? model.id).match(/\d+/g) ??
    []
  ).map(Number);

function newer(a: Model, b: Model): boolean {
  const left = version(a);
  const right = version(b);
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference) return difference > 0;
  }
  // A context/mode variant belongs under More models when the ordinary model is also present.
  const variant = (model: Model) => model.id.includes("[") || model.name.includes(" · ");
  return variant(b) && !variant(a);
}

export function relevantModelSections<T extends Model>(
  models: readonly T[],
  top: readonly string[] | undefined,
): { shown: T[]; more: T[] } {
  const available = (model: T) => (model.offers ?? [model]).some((offer) => !offer.unavailable);
  const chosen = new Set<T>();
  if (top !== undefined) {
    for (const id of top) {
      const model = models.find((candidate) =>
        (candidate.offers ?? [candidate]).some((offer) => offer.id === id || offer.release === id),
      );
      if (model && available(model)) chosen.add(model);
    }
  } else {
    const families = new Map<string, T>();
    for (const model of models) {
      if (!available(model)) continue;
      const key = familyKey(model);
      const previous = families.get(key);
      if (!previous || newer(model, previous)) families.set(key, model);
    }
    for (const model of families.values()) chosen.add(model);
  }
  return { shown: [...chosen], more: models.filter((model) => !chosen.has(model)) };
}

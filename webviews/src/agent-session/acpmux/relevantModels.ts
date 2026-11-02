// The harness owns its default menu. Preserve that list and its order when it reports one;
// only a harness without a menu report falls back to its newest available model per family.
// Provider duplicates have already been grouped. Current/recent selections never promote rows.
import currentFamilies from "../../../../web/data/model-catalog/current-families.json";

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

// This orders known families, never limits their number or pins a reported family's version.
const familyOrder = new Map(
  Object.values(currentFamilies)
    .flat()
    .flatMap((model, index): [string, number][] => [
      [familyKey(model), index],
      [familyKey({ ...model, family: undefined }), index],
    ]),
);

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

/** `a` is a strictly older version than `b`. A variant of the same version is not, nor is a model
 *  whose name and id carry no version (a bare alias). A snapshot date is no version part, so
 *  `claude-opus-4-5` is not older than its dated snapshot `claude-opus-4-5-20251101`. */
function olderVersion(a: Model, b: Model): boolean {
  const release = (model: Model) => version(model).filter((part) => part < 100_000);
  const left = release(a);
  const right = release(b);
  if (left.length === 0 || right.length === 0) return false;
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference) return difference < 0;
  }
  return false;
}

/** One product line: the declared family and the version-stripped id together, so a harness whose
 *  families are whole vendors ("OpenAI", "Google") never folds one product line under another. */
const lineKey = (model: Model) => `${familyKey(model)}\u0000${familyKey({ ...model, family: undefined })}`;

export function relevantModelSections<T extends Model>(
  models: readonly T[],
  top: readonly string[] | undefined,
  running?: string,
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
    // A harness that reports its whole live list (Codex: every GPT generation) would otherwise
    // list its tab flat while one that reports a short menu (Claude Code) folds the rest under
    // Legacy models (https://github.com/manaflow-ai/cmux/issues/29915). A menu model of a declared
    // catalog family whose product line the same menu also lists at a newer version folds, so every
    // tab shows its lines' current versions. Context variants of one version stay, inferred families
    // never fold, and the chat's running model keeps its row: folding never hides the live choice.
    const isRunning = (model: T) =>
      !!running && (model.offers ?? [model]).some((offer) => offer.id === running || offer.release === running);
    const newest = new Map<string, T>();
    for (const model of chosen) {
      if (!model.family) continue;
      const key = lineKey(model);
      const previous = newest.get(key);
      if (!previous || olderVersion(previous, model)) newest.set(key, model);
    }
    for (const model of chosen) {
      const lead = model.family ? newest.get(lineKey(model)) : undefined;
      if (lead && olderVersion(model, lead) && !isRunning(model)) chosen.delete(model);
    }
  } else {
    const families = new Map<string, T>();
    for (const model of models) {
      if (!available(model)) continue;
      const key = familyKey(model);
      const previous = families.get(key);
      if (!previous || newer(model, previous)) families.set(key, model);
    }
    const ordered = [...families.values()].sort(
      (a, b) => (familyOrder.get(familyKey(a)) ?? Infinity) - (familyOrder.get(familyKey(b)) ?? Infinity),
    );
    for (const model of ordered) chosen.add(model);
  }
  return { shown: [...chosen], more: models.filter((model) => !chosen.has(model)) };
}

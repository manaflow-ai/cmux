import { agentName } from "./agents";
import { isDefaultChoice } from "./defaultChoice";
import type { ModelPickerProps } from "./modelPickerLayout";

export type HarnessChoice = {
  id: string;
  ids: string[];
  name: string;
  models: { id: string; name?: string; unavailable?: string }[];
  unavailable?: string;
  acpmuxHarness?: string;
  pickable: boolean;
  /** A profile from the chat's folder and its state. */
  folder?: ModelPickerProps["catalog"][number]["folder"];
  /** The brand the row's mark draws (a folder profile's icon or family, else its id). */
  mark?: string;
};

export type ModelChoice = {
  id: string;
  name: string;
  unavailable?: string;
  version: number[];
  order: number;
};

function versionOf(model: { id: string; name?: string }): number[] {
  const text = model.name ?? model.id;
  const match = /\d+(?:\.\d+)*/.exec(text);
  return match ? match[0].split(".").map(Number) : (model.id.match(/\d+/g) ?? []).map(Number);
}

function compareVersions(a: ModelChoice, b: ModelChoice): number {
  const length = Math.max(a.version.length, b.version.length);
  for (let index = 0; index < length; index += 1) {
    const difference = (a.version[index] ?? -1) - (b.version[index] ?? -1);
    if (difference !== 0) return difference;
  }
  return a.order - b.order;
}

export function choicesFor(entry: HarnessChoice | undefined): ModelChoice[] {
  if (!entry) return [];
  const seen = new Set<string>();
  const choices = entry.models.flatMap((model, order) => {
    if (seen.has(model.id)) return [];
    seen.add(model.id);
    return [
      {
        id: model.id,
        name: isDefaultChoice(model) ? "Default" : model.name || model.id,
        unavailable: model.unavailable,
        version: versionOf(model),
        order,
      },
    ];
  });
  const defaults = choices.filter((choice) => isDefaultChoice(choice));
  const models = choices.filter((choice) => !isDefaultChoice(choice)).sort(compareVersions);
  // The list is deliberately stable. Newest and best models sit nearest the anchor at the bottom.
  return [...defaults, ...models];
}

export function uniqueHarnesses(catalog: ModelPickerProps["catalog"]): HarnessChoice[] {
  const profiles: HarnessChoice[] = catalog
    .filter((entry) => entry.folder)
    .map((entry) => ({
      id: entry.id,
      ids: [entry.id],
      name: entry.name,
      models: entry.models,
      unavailable: entry.unavailable,
      acpmuxHarness: entry.id,
      pickable: entry.pickable !== false,
      folder: entry.folder,
      mark: entry.icon ?? entry.family ?? entry.id,
    }));
  // Terminal and unknown harnesses are routing entries, not installed choices.
  const entries: HarnessChoice[] = catalog
    .filter((entry) => !entry.folder && entry.pickable !== false)
    .map((entry) => ({
      id: entry.id,
      ids: [entry.id],
      name: entry.name,
      models: entry.models,
      unavailable: entry.unavailable,
      acpmuxHarness: entry.id,
      pickable: entry.pickable !== false,
    }));
  const result: HarnessChoice[] = [];
  const byName = new Map<string, HarnessChoice>();
  for (const entry of entries) {
    const name = agentName(entry.id, entry.name);
    const existing = byName.get(name);
    if (!existing) {
      const next = {
        id: entry.id,
        ids: [entry.id],
        name,
        models: [...entry.models],
        unavailable: entry.unavailable,
        acpmuxHarness: entry.acpmuxHarness,
        pickable: entry.pickable,
      };
      result.push(next);
      byName.set(name, next);
      continue;
    }
    existing.ids.push(entry.id);
    if (entry.acpmuxHarness && !existing.acpmuxHarness) existing.acpmuxHarness = entry.acpmuxHarness;
    existing.pickable ||= entry.pickable;
    const known = new Set(existing.models.map((model) => model.id));
    for (const model of entry.models) if (!known.has(model.id)) existing.models.push(model);
    existing.unavailable ??= entry.unavailable;
  }
  return [...result, ...profiles];
}

/// A folder profile row the user cannot start yet: waiting for the folder's Trust answer, or broken.
export const blockedProfile = (entry: HarnessChoice | undefined) =>
  entry?.folder?.state === "needs-trust" || entry?.folder?.state === "error";

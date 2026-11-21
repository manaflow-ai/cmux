// Run on N agents: the composer's prompt sent to 2 to 4 agents at once, each a sub-session in a
// worktree of its own (acpmux `_acpmux/plan/fanout`, hub/plan_build.rs). The chat then shows the
// same builds card a plan approval's compare does (planBuild/PlanBuildCard.tsx): each run's diff,
// and Keep this one, which closes the others and removes their worktrees. This is the picker's
// model: which agents a run starts with, and what each one is called.

import type { PickerCatalog, PickerHarness, PickerModel } from "../modelCatalogData";

/// One run's agent: a harness, and the model and effort it runs (none: the harness's default).
export type RunVariant = { harness: string; model?: string; effort?: string };

/// The fewest agents a run starts: one is a plain send.
export const MIN_RUNS = 2;
/// The most: each run is a worktree and an agent's turn (acpmux `MAX_RUNS`).
export const MAX_RUNS = 4;

/// The harnesses a run may use: installed, pickable, and named for acpmux.
export function runHarnesses(catalog: PickerCatalog | undefined): PickerHarness[] {
  return (catalog?.harnesses ?? []).filter((h) => h.installed && h.pickable && h.acpmuxHarness && !h.unavailable);
}

const harnessId = (h: PickerHarness) => h.acpmuxHarness ?? h.id;

/// The first of `harness`'s models whose id names `family` ("opus", "sonnet").
function modelOf(harness: PickerHarness | undefined, family: string): PickerModel | undefined {
  return harness?.models.find((m) => m.id.toLowerCase().includes(family) && !m.unavailable);
}

/// The agents a run starts with: Claude Opus, Codex and Claude Sonnet when they are here, else
/// the installed harnesses in turn; never fewer than two when two can run.
export function defaultVariants(catalog: PickerCatalog | undefined): RunVariant[] {
  const harnesses = runHarnesses(catalog);
  const claude = harnesses.find((h) => h.id === "claude" || h.family === "claude");
  const codex = harnesses.find((h) => h.id === "codex" || h.family === "codex");
  const picked: RunVariant[] = [];
  const opus = modelOf(claude, "opus");
  const sonnet = modelOf(claude, "sonnet");
  if (claude) picked.push({ harness: harnessId(claude), ...(opus ? { model: opus.id } : {}) });
  if (codex) picked.push({ harness: harnessId(codex) });
  if (claude && sonnet) picked.push({ harness: harnessId(claude), model: sonnet.id });
  for (const h of harnesses) {
    if (picked.length >= MIN_RUNS) break;
    if (!picked.some((v) => v.harness === harnessId(h))) picked.push({ harness: harnessId(h) });
  }
  return picked.slice(0, MAX_RUNS);
}

/// The agent a new row adds: the first installed harness the run does not use yet, else the
/// first one again.
export function nextVariant(
  catalog: PickerCatalog | undefined,
  current: readonly RunVariant[],
): RunVariant | undefined {
  const harnesses = runHarnesses(catalog);
  const unused = harnesses.find((h) => !current.some((v) => v.harness === harnessId(h)));
  const pick = unused ?? harnesses[0];
  return pick ? { harness: harnessId(pick) } : undefined;
}

/// A variant's harness entry in the catalog.
export function variantHarness(catalog: PickerCatalog | undefined, variant: RunVariant): PickerHarness | undefined {
  return catalog?.harnesses.find((h) => harnessId(h) === variant.harness);
}

/// What a variant reads as: "Claude · Opus 5.5 · high", "Codex".
export function variantLabel(catalog: PickerCatalog | undefined, variant: RunVariant): string {
  const harness = variantHarness(catalog, variant);
  const model = variant.model ? harness?.models.find((m) => m.id === variant.model) : undefined;
  return [harness?.name ?? variant.harness, model?.shortName ?? variant.model, variant.effort]
    .filter(Boolean)
    .join(" · ");
}

/// The efforts `variant`'s model offers, in the catalog's order.
export function variantEfforts(catalog: PickerCatalog | undefined, variant: RunVariant): string[] {
  const harness = variantHarness(catalog, variant);
  const model = variant.model ? harness?.models.find((m) => m.id === variant.model) : undefined;
  return model?.efforts ?? [];
}

/// `variant` with another model: an effort that model does not offer goes.
export function withModel(catalog: PickerCatalog | undefined, variant: RunVariant, model?: string): RunVariant {
  const next: RunVariant = { harness: variant.harness, ...(model ? { model } : {}) };
  if (variant.effort && variantEfforts(catalog, next).includes(variant.effort)) next.effort = variant.effort;
  return next;
}

/// The variants as `_acpmux/plan/fanout` takes them, or undefined when the count is out of range.
export function fanoutVariants(variants: readonly RunVariant[]): RunVariant[] | undefined {
  if (variants.length < MIN_RUNS || variants.length > MAX_RUNS) return undefined;
  return variants.map((v) => ({
    harness: v.harness,
    ...(v.model ? { model: v.model } : {}),
    ...(v.effort ? { effort: v.effort } : {}),
  }));
}

/// Whether a chat offers Run on N agents: only one that exists on this Mac. A new chat, the Quick
/// Composer, Cloud or Sandboxed picked for a new chat have no chat to start runs from, and acpmux
/// refuses the runs from a chat on another machine (SSH, Cloud: server/plan_build.rs).
export function runOnOffered(chat: {
  quick: boolean;
  sessionId: string | undefined;
  cloudPicked: boolean;
  sandboxing: boolean;
  onOtherMachine: boolean;
}): boolean {
  return !chat.quick && Boolean(chat.sessionId) && !chat.cloudPicked && !chat.sandboxing && !chat.onOtherMachine;
}

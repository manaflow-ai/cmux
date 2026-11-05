// A suggested task's Options (SuggestedTasks.tsx): where and how its new chat starts, as Claude
// desktop's suggested-session card has it (Environment, the folder, Worktree, Model, Effort,
// Permissions). Each row starts at this chat's own value; the person's picks ride on Start
// (`chat.offer.start`, direct.ts `startOffer`). Leo, 2026-11-05, on that card: "I want to be able
// to, like, recommend Claude to be able to do that as well. in our cmux-next app. and have it be
// rendered."
import { createContext, useContext } from "react";
import type { AcpmuxSnapshot, AcpmuxSessionOffer } from "../model";
import { sessionModels } from "../modelCatalog";

type Summary = AcpmuxSnapshot["summary"];
type Catalog = AcpmuxSnapshot["catalog"];

/// What a task's Start carries: the worktree switch, and the model, effort and permission mode
/// picked in Options (unset: the new chat's own default).
export type OfferChoice = {
  worktree: boolean;
  model?: string;
  effort?: { configId: string; value: string };
  mode?: string;
};

type Choice = { value: string; name: string };

/// This chat's own values, which a task's Options start from.
export type OfferDefaults = {
  /// The machine the chat runs on: unset for this computer.
  machine?: string;
  harness?: string;
  model?: string;
  models: Choice[];
  effort?: { configId: string; value?: string; options: Choice[] };
  mode?: string;
  modes: Choice[];
};

/// The shown chat's defaults (App.tsx provides them around the transcript); unset outside a chat.
export const OfferDefaultsContext = createContext<OfferDefaults | undefined>(undefined);

export function useOfferDefaults(): OfferDefaults | undefined {
  return useContext(OfferDefaultsContext);
}

/// The defaults of the chat `summary` describes.
export function offerDefaults(summary: Summary | undefined, catalog: Catalog): OfferDefaults {
  const effort = summary?.configOptions?.find(
    (option) => option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort",
  );
  return {
    ...(summary?.hostKind === "cloud" || summary?.peer
      ? { machine: summary.machine ?? summary.peer ?? summary.host }
      : {}),
    ...(summary?.harness ? { harness: summary.harness } : {}),
    ...(summary?.model ? { model: summary.model } : {}),
    models: sessionModels(catalog, summary).map((model) => ({ value: model.id, name: model.name })),
    ...(effort && {
      effort: {
        configId: effort.id,
        ...(effort.currentValue ? { value: effort.currentValue } : {}),
        options: effort.options.map((option) => ({ value: option.value, name: option.name || option.value })),
      },
    }),
    ...(summary?.modes?.currentModeId ? { mode: summary.modes.currentModeId } : {}),
    modes: (summary?.modes?.availableModes ?? []).map((mode) => ({ value: mode.id, name: mode.name || mode.id })),
  };
}

/// Whether this chat's model, effort and mode lists apply to `offer`: it runs on this chat's agent.
export function sameAgent(offer: AcpmuxSessionOffer, defaults: OfferDefaults | undefined): defaults is OfferDefaults {
  return Boolean(defaults) && (!offer.harness || offer.harness === defaults!.harness);
}

/// The choice a task starts with untouched: the agent's worktree ask, the agent's model else this
/// chat's, and this chat's effort and mode.
export function initialChoice(offer: AcpmuxSessionOffer, defaults: OfferDefaults | undefined): OfferChoice {
  if (!sameAgent(offer, defaults)) return { worktree: offer.worktree, ...(offer.model ? { model: offer.model } : {}) };
  const model = offer.model ?? defaults.model;
  return {
    worktree: offer.worktree,
    ...(model ? { model } : {}),
    ...(defaults.effort?.value ? { effort: { configId: defaults.effort.configId, value: defaults.effort.value } } : {}),
    ...(defaults.mode ? { mode: defaults.mode } : {}),
  };
}

/// The last part of a folder path (`/Users/you/Projects` is `Projects`), and the folder holding it.
export function folderParts(cwd: string): { name: string; parent: string } {
  const trimmed = cwd.replace(/\/+$/, "") || "/";
  const at = trimmed.lastIndexOf("/");
  if (at <= 0) return { name: trimmed, parent: at === 0 && trimmed !== "/" ? "/" : "" };
  return { name: trimmed.slice(at + 1), parent: trimmed.slice(0, at) };
}

/// The Options picks a Start carries to the new chat (direct.ts `startOffer`).
export type OfferPicks = Omit<OfferChoice, "worktree">;

/// `chat.offer.start`'s picks, read from its params: only well-formed values.
export function offerPicks(model: unknown, effort: unknown, mode: unknown): OfferPicks {
  const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
  const pick = effort && typeof effort === "object" ? (effort as Record<string, unknown>) : undefined;
  const [configId, value] = [text(pick?.configId), text(pick?.value)];
  return {
    ...(text(model) ? { model: text(model) } : {}),
    ...(configId && value ? { effort: { configId, value } } : {}),
    ...(text(mode) ? { mode: text(mode) } : {}),
  };
}

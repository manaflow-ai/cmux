// A suggested task's Options (SuggestedTasks.tsx): where and how its new chat starts, as Claude
// desktop's suggested-session card has it (Environment, the folder, Worktree, Model, Effort,
// Permissions). Environment and the folder are where it runs. Model, Effort and Permissions list
// this chat's agent's choices and start at "Default", the new chat's own; only what the person
// picks rides on Start (`chat.offer.start`, direct.ts `startOffer`). An Effort or Permissions pick
// is a grant, so it carries a gesture ticket bound to that exact pick (`transport.gesture`), and a
// pick the new chat cannot take stops the start before its prompt. Leo, 2026-11-05, on that card: "I want to be able
// to, like, recommend Claude to be able to do that as well. in our cmux-next app. and have it be
// rendered."
import { createContext, useContext } from "react";
import type { AcpmuxSnapshot, AcpmuxSessionOffer } from "../model";
import { sessionModels } from "../modelCatalog";

type Summary = AcpmuxSnapshot["summary"];
type Catalog = AcpmuxSnapshot["catalog"];

/// What a task's Start carries: the worktree switch, and the model, effort and permission mode
/// picked in Options (unset: the new chat's own default). `harness`: this chat's agent, set with a
/// pick from its lists when the offer names no agent, so the new chat runs on the agent those
/// lists are for, not the person's default one.
export type OfferChoice = {
  worktree: boolean;
  harness?: string;
  model?: string;
  effort?: { configId: string; value: string };
  mode?: string;
};

type Choice = { value: string; name: string; disabled?: boolean };

/// This chat's machine and agent, and the choices its agent offers, which a task's Options list.
export type OfferDefaults = {
  /// The machine the chat runs on: unset for this computer.
  machine?: string;
  harness?: string;
  /// A model acpmux will not run is listed, disabled.
  models: Choice[];
  effort?: { configId: string; options: Choice[] };
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
  const unavailable = new Set(
    (catalog.find((harness) => harness.id === summary?.harness)?.models ?? [])
      .filter((model) => model.unavailable)
      .map((model) => model.id),
  );
  return {
    ...(summary?.hostKind === "cloud" || summary?.peer
      ? { machine: summary.machine ?? summary.peer ?? summary.host }
      : {}),
    ...(summary?.harness ? { harness: summary.harness } : {}),
    models: sessionModels(catalog, summary).map((model) => ({
      value: model.id,
      name: model.name,
      ...(unavailable.has(model.id) ? { disabled: true } : {}),
    })),
    ...(effort && {
      effort: {
        configId: effort.id,
        options: effort.options.map((option) => ({ value: option.value, name: option.name || option.value })),
      },
    }),
    modes: (summary?.modes?.availableModes ?? []).map((mode) => ({ value: mode.id, name: mode.name || mode.id })),
  };
}

/// Whether this chat's model, effort and mode lists apply to `offer`: it runs on this chat's agent.
export function sameAgent(offer: AcpmuxSessionOffer, defaults: OfferDefaults | undefined): defaults is OfferDefaults {
  return Boolean(defaults) && (!offer.harness || offer.harness === defaults!.harness);
}

/// The choice a task starts with untouched: the agent's worktree ask and model, nothing else, so
/// the new chat starts as any new chat of its agent does.
export function initialChoice(offer: AcpmuxSessionOffer): OfferChoice {
  return { worktree: offer.worktree, ...(offer.model ? { model: offer.model } : {}) };
}

/// A pick from this chat's lists.
export type OfferPick = Pick<OfferChoice, "model" | "effort" | "mode">;

/// `choice` with a pick from this chat's lists (Model, Effort, Permissions): it also pins this
/// chat's agent when the offer names none.
export function withPick(
  choice: OfferChoice,
  offer: AcpmuxSessionOffer,
  defaults: OfferDefaults,
  pick: OfferPick,
): OfferChoice {
  return { ...choice, ...(!offer.harness && defaults.harness ? { harness: defaults.harness } : {}), ...pick };
}

/// A grant's gesture intent (`transport.gesture`): its ticket redeems only that exact pick.
export type OfferGrant = { method: string; params: Record<string, string> };

/// The tickets a Start's Effort and Permissions picks go under.
export type OfferTickets = { mode?: Promise<string | undefined>; effort?: Promise<string | undefined> };

/// The gesture intent that grants `pick` to the new chat.
export function pickIntent(pick: { mode: string } | { effort: { configId: string; value: string } }): OfferGrant {
  return "mode" in pick
    ? { method: "session/set_mode", params: { modeId: pick.mode } }
    : { method: "session/set_config_option", params: { configId: pick.effort.configId, value: pick.effort.value } };
}

/// The last part of a folder path (`/Users/you/Projects` is `Projects`), and the folder holding it.
export function folderParts(cwd: string): { name: string; parent: string } {
  const trimmed = cwd.replace(/\/+$/, "") || "/";
  const at = trimmed.lastIndexOf("/");
  if (at <= 0) return { name: trimmed, parent: at === 0 && trimmed !== "/" ? "/" : "" };
  return { name: trimmed.slice(at + 1), parent: trimmed.slice(0, at) };
}

/// The Options picks a Start carries to the new chat (direct.ts `startOffer`), with the gesture
/// ticket each grant goes under.
export type OfferPicks = Omit<OfferChoice, "worktree"> & { modeTicket?: string; effortTicket?: string };

/// `chat.offer.start`'s picks, read from its params: only well-formed values.
export function offerPicks(params: Record<string, unknown>): OfferPicks {
  const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
  const pick =
    params.effort && typeof params.effort === "object" ? (params.effort as Record<string, unknown>) : undefined;
  const [configId, value] = [text(pick?.configId), text(pick?.value)];
  const field = (key: "harness" | "model" | "mode" | "modeTicket" | "effortTicket") =>
    text(params[key]) ? { [key]: text(params[key]) } : {};
  return {
    ...field("harness"),
    ...field("model"),
    ...(configId && value ? { effort: { configId, value } } : {}),
    ...field("mode"),
    ...field("modeTicket"),
    ...field("effortTicket"),
  };
}

// A `_acpmux/harnesses` reply as the picker's catalog. Moved out of direct.ts so the model catalog
// reads it without the connection client.
import { agentName } from "./agents";
import type { AcpmuxSnapshot, StartSource } from "./model";
import { reportsModes, reportsNoModes } from "./permissionModes";
import { isModelRouterKind } from "./routerKinds";
import { parseHarnessIconSpec, rememberHarnessIcons } from "../shared/harnessIcons";

export function harnessRefusal(entry: { unavailable?: unknown; probeError?: unknown } | undefined): string | undefined {
  for (const reason of [entry?.unavailable, entry?.probeError]) if (typeof reason === "string" && reason) return reason;
  return undefined;
}

/// One `_acpmux/models` entry: id and name, plus the metadata a declared profile model carries.
export function catalogModel(model: any): AcpmuxSnapshot["catalog"][number]["models"][number] {
  const entry: AcpmuxSnapshot["catalog"][number]["models"][number] = {
    id: String(model?.id ?? model?.modelId),
    name: typeof model?.name === "string" ? model.name : undefined,
  };
  if (typeof model?.unavailable === "string") entry.unavailable = model.unavailable;
  for (const key of ["curated", "declared"] as const) if (typeof model?.[key] === "boolean") entry[key] = model[key];
  for (const key of ["shortName", "family", "defaultEffort"] as const)
    if (typeof model?.[key] === "string" && model[key]) entry[key] = model[key];
  if (Array.isArray(model?.efforts))
    entry.efforts = model.efforts.filter((value: unknown) => typeof value === "string");
  if (typeof model?.fast === "boolean") entry.fast = model.fast;
  if (Number.isInteger(model?.contextWindow) && model.contextWindow > 0) entry.contextWindow = model.contextWindow;
  return entry;
}

/// A harness map's entries in acpmux's order: its default (`defaultHarness`) first, then by id. The
/// native relay re-encodes the reply, so the map's own key order means nothing (a first launch
/// asked the model router instead of Claude Code).
function harnessEntries(harnesses: Record<string, unknown>, preferred: unknown): any[] {
  const ids = Object.keys(harnesses).sort((a, b) =>
    a === preferred ? -1 : b === preferred ? 1 : a < b ? -1 : a > b ? 1 : 0,
  );
  return ids.map((id) => ({ id, ...(harnesses[id] as any) }));
}

/// `_acpmux/harnesses` `start` ({model?, effort?, modelSource?, effortSource?}), with only its
/// known fields.
function harnessStart(value: unknown): AcpmuxSnapshot["catalog"][number]["start"] {
  if (!value || typeof value !== "object") return undefined;
  const { model, effort, modelSource, effortSource } = value as Record<string, unknown>;
  const source = (raw: unknown) =>
    raw === "saved" || raw === "profile" || raw === "catalog" ? (raw as StartSource) : undefined;
  const start = {
    ...(typeof model === "string" && model ? { model } : {}),
    ...(typeof effort === "string" && effort ? { effort } : {}),
    ...(source(modelSource) ? { modelSource: source(modelSource) } : {}),
    ...(source(effortSource) ? { effortSource: source(effortSource) } : {}),
  };
  return start.model || start.effort ? start : undefined;
}

export function normalizeCatalog(value: any): AcpmuxSnapshot["catalog"] {
  const harnesses = value?.harnesses ?? value?.items ?? value ?? [];
  const entries: any[] = Array.isArray(harnesses) ? harnesses : harnessEntries(harnesses, value?.defaultHarness);
  const catalog = entries.map(catalogEntry);
  // Every AgentMark given a harness id draws its icon (shared/harnessIcons.ts).
  rememberHarnessIcons(catalog);
  return catalog;
}

function catalogEntry(harness: any): AcpmuxSnapshot["catalog"][number] {
  const iconSpec = parseHarnessIconSpec(harness.iconSpec);
  return {
    id: String(harness.id ?? harness.name),
    name: agentName(
      String(harness.id ?? harness.name),
      typeof harness.displayName === "string" && harness.displayName
        ? harness.displayName
        : harness.name == null
          ? undefined
          : String(harness.name),
    ),
    models: (harness.models ?? []).map((model: any) => catalogModel(model)),
    ...(typeof harness.kind === "string" ? { kind: harness.kind } : {}),
    ...(typeof harness.family === "string" && harness.family ? { family: harness.family } : {}),
    ...(typeof harness.icon === "string" && harness.icon ? { icon: harness.icon } : {}),
    ...(iconSpec ? { iconSpec } : {}),
    // Terminals and model routers are not chat harness choices. A real launcher can still have
    // a cmux-prefixed ID: only the declared kind determines whether it belongs in the picker.
    // acpmux's `pickerHidden`: the cmux model router profile, Claude's automatic fallback.
    ...(harness.kind === "terminal" || isModelRouterKind(harness.kind) || harness.pickerHidden === true
      ? { pickable: false }
      : {}),
    ...(harnessStart(harness.start) ? { start: harnessStart(harness.start) } : {}),
    // Its chats report no permission modes (`reported`): a new chat on it draws no Mode chip.
    ...(reportsNoModes(harness.reported) ? { modeless: true as const } : {}),
    // Its chats (or its startup probe) report permission modes: a new chat holds its Mode chip.
    ...(reportsModes(harness.reported) ? { reportsModes: true as const } : {}),
    ...(typeof harness.auth?.login === "string" && harness.auth.login.trim()
      ? { auth: { login: harness.auth.login.trim() } }
      : {}),
    // Why acpmux will not start it, when it says: its launcher check (`unavailable`), else its
    // failed model probe (`probeError`).
    ...(harnessRefusal(harness) ? { unavailable: harnessRefusal(harness) } : {}),
    ...(!harness.unavailable && harnessRefusal(harness) ? { probeFailed: true } : {}),
  };
}

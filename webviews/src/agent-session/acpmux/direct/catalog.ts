import { isModelRouterKind } from "../routerKinds";
import type { AcpmuxSnapshot, StartSource } from "../model";
import { agentName } from "../agents";
import { parseHarnessIconSpec, rememberHarnessIcons } from "../../shared/harnessIcons";
import { reportsModes, reportsNoModes } from "../permissionModes";
import { harnessRefusal } from "./refusals";

const FOLDER_STATES = ["enabled", "needs-enable", "needs-trust", "error"] as const;

/// The folder profiles of a `_acpmux/harnesses {cwd}` reply (`folderProfiles`) as catalog entries.
/// An entry without an id, a folder or a known state is dropped.
export function normalizeFolderProfiles(value: any): AcpmuxSnapshot["catalog"] {
  const profiles: any[] = Array.isArray(value?.folderProfiles) ? value.folderProfiles : [];
  return profiles.flatMap((profile) => {
    const id = typeof profile?.id === "string" ? profile.id : "";
    const folder = typeof profile?.folder === "string" ? profile.folder : "";
    const state = FOLDER_STATES.find((candidate) => candidate === profile?.state);
    if (!id || !folder || !state) return [];
    const first = Array.isArray(profile.diagnostics) ? profile.diagnostics[0] : undefined;
    const diagnostic =
      typeof first === "string" ? first : typeof first?.message === "string" ? first.message : undefined;
    return [
      {
        id,
        name: typeof profile.displayName === "string" && profile.displayName ? profile.displayName : id,
        models: Array.isArray(profile.models) ? profile.models.map((model: unknown) => catalogModel(model)) : [],
        ...(typeof profile.family === "string" && profile.family ? { family: profile.family } : {}),
        ...(typeof profile.icon === "string" && profile.icon ? { icon: profile.icon } : {}),
        folder: {
          folder,
          ...(typeof profile.path === "string" ? { path: profile.path } : {}),
          state,
          ...(diagnostic ? { diagnostic } : {}),
        },
      },
    ];
  });
}

/// One `_acpmux/models` entry: id and name, plus the metadata a declared profile model carries.
export function catalogModel(model: any): AcpmuxSnapshot["catalog"][number]["models"][number] {
  const entry: AcpmuxSnapshot["catalog"][number]["models"][number] = {
    id: String(model?.id ?? model?.modelId),
    name: typeof model?.name === "string" ? model.name : undefined,
  };
  if (typeof model?.unavailable === "string") entry.unavailable = model.unavailable;
  if (entry.unavailable && typeof model?.codexUpdateVersion === "string")
    entry.codexUpdateVersion = model.codexUpdateVersion;
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
  // acpmux's harness map named none of them its default (a Mac with only the built-in Chief and
  // UniiChat, default_harness.rs): New Tab then starts on no agent and offers Add harness.
  const preferred = value?.defaultHarness;
  const noDefault =
    !Array.isArray(harnesses) &&
    harnesses !== value &&
    entries.length > 0 &&
    !(typeof preferred === "string" && entries.some((entry) => entry.id === preferred));
  const catalog = entries.map((entry) =>
    noDefault ? { ...catalogEntry(entry), noDefault: true as const } : catalogEntry(entry),
  );
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
    ...(reportsModes(harness.reported) ? reportedModes(harness.reported) : {}),
    ...(typeof harness.auth?.login === "string" && harness.auth.login.trim()
      ? { auth: { login: harness.auth.login.trim() } }
      : {}),
    // Why acpmux will not start it, when it says: its launcher check (`unavailable`), else its
    // failed model probe (`probeError`).
    ...(harnessRefusal(harness) ? { unavailable: harnessRefusal(harness) } : {}),
    ...(!harness.unavailable && harnessRefusal(harness) ? { probeFailed: true } : {}),
  };
}

/// A harness row's reported modes as a new chat's Mode menu rows, and the mode the harness starts a
/// chat in when acpmux sets none (`reported.startModeId`) when it is one of them.
function reportedModes(reported: any): Pick<AcpmuxSnapshot["catalog"][number], "reportedModes" | "ownStartMode"> {
  const rows = (Array.isArray(reported?.modes) ? reported.modes : []).flatMap((mode: any) =>
    typeof mode?.id === "string" && mode.id
      ? [
          {
            id: mode.id as string,
            ...(typeof mode.name === "string" && mode.name ? { name: mode.name as string } : {}),
            ...(typeof mode.description === "string" && mode.description
              ? { description: mode.description as string }
              : {}),
          },
        ]
      : [],
  );
  const own = typeof reported?.startModeId === "string" ? reported.startModeId : undefined;
  return {
    ...(rows.length > 0 ? { reportedModes: rows } : {}),
    ...(own && rows.some((row: { id: string }) => row.id === own) ? { ownStartMode: own } : {}),
  };
}

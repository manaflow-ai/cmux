/// The Cloud Environment chip's model (CloudEnvironmentChip.tsx), behind the launch flag
/// CLOUD_ENVIRONMENTS_ENABLED (composerSettings.ts `cloudEnvironments`). Leo, 2026-11-07: "you pick
/// the cloud thing, and then you have another thing, drop down, or, you know, drop up ... it's auto
/// by default, but then you can also say create environment."
///
/// - Auto is the default and sends no environment: `cloud.startChat` then boots the chat from the
///   repository's set-up snapshot in the person's Default environment, derived from the chat's
///   folder or repository with no questions (cmux-tui link/start_chat_cli.rs, cmux-platform
///   `POST /v1/environments/derive`).
/// - Any other pick is one of the account's Cloud environments (`cloud.environment.list`, cmux-platform
///   `GET /v1/cloud-environments`), sent as `cloud.startChat`'s `environment`.
/// - The drop-up lists the project's recent environments: the ones picked for this folder, most
///   recent first. The platform keeps no per-project list, so this page remembers them; a folder with
///   none yet lists the account's most recently changed ones.

import type { CloudEnvironment } from "../../pages/cloud/environmentModel";
import { composerSettingsSnapshot } from "./composerSettings";

/// The pick that sends no environment.
export const AUTO_ENVIRONMENT = "auto";
/// How many recent environments the drop-up lists.
export const RECENT_ENVIRONMENTS = 3;

/// One environment as the chip lists it.
export type CloudEnvironmentChoice = { id: string; name: string };

/// The drop-up's rows, in order (the coordinator's spec for HQ ask-0f9527cc9e):
/// Auto, the project's recent environments, New environment…, Edit <current>…, then New Cloud
/// machine… as the manual fallback after a hairline.
export type CloudEnvironmentRow =
  | { kind: "auto" }
  | { kind: "environment"; environment: CloudEnvironmentChoice }
  | { kind: "new" }
  | { kind: "edit"; name: string; id?: string }
  | { kind: "separator" }
  | { kind: "newMachine" };

/// What the composer's strip hands the chip (ComposerContext `cloudEnvironment`).
export type CloudEnvironmentControl = {
  /// The project's recent environments, most recent first (`recentEnvironments`).
  recent: readonly CloudEnvironmentChoice[];
  /// The pick: AUTO_ENVIRONMENT or an environment's id.
  current: string;
  /// The current pick's name when it is not among `recent` (picked elsewhere, or not listed yet).
  currentName?: string;
  /// The environment Auto runs in (the account's Default), which Edit opens while Auto is the pick.
  auto?: CloudEnvironmentChoice;
  onPick(id: string): void;
  onNew(): void;
  /// Edit the environment: its id, or none for Auto's (the Default, derived from the repository).
  onEdit(id: string | undefined): void;
  /// New Cloud machine…: a machine from the picked environment (none for Auto), with a terminal on it.
  onNewMachine(environment: string | undefined): void;
  /// The drop-up opened: read the account's environments again.
  onOpen?(): void;
};

/// The rows of the drop-up, in order. The current pick, when it is not Auto and not among the recent
/// ones, is listed after them, so the checked row is never hidden.
export function cloudEnvironmentRows(control: CloudEnvironmentControl, autoName: string): CloudEnvironmentRow[] {
  const listed = control.recent.slice(0, RECENT_ENVIRONMENTS);
  const pickedOther =
    control.current !== AUTO_ENVIRONMENT && !listed.some((environment) => environment.id === control.current)
      ? { id: control.current, name: control.currentName ?? control.current }
      : undefined;
  const current = currentEnvironment(control, autoName);
  return [
    { kind: "auto" },
    ...listed.map((environment) => ({ kind: "environment" as const, environment })),
    ...(pickedOther ? [{ kind: "environment" as const, environment: pickedOther }] : []),
    { kind: "new" },
    { kind: "edit", name: current.name, ...(current.id ? { id: current.id } : {}) },
    { kind: "separator" },
    { kind: "newMachine" },
  ];
}

/// The environment a pick runs in, by name: Auto's is the account's Default (or "Auto" until it is
/// known); any other its own name.
export function currentEnvironment(control: CloudEnvironmentControl, autoName: string): { id?: string; name: string } {
  if (control.current === AUTO_ENVIRONMENT) return { name: control.auto?.name ?? autoName };
  const listed = control.recent.find((environment) => environment.id === control.current);
  return { id: control.current, name: listed?.name ?? control.currentName ?? control.current };
}

/// The chip's value: "Auto", or the picked environment's name.
export function cloudEnvironmentValue(control: CloudEnvironmentControl, autoName: string): string {
  return control.current === AUTO_ENVIRONMENT ? autoName : currentEnvironment(control, autoName).name;
}

/// What a Cloud start sends as `environment`: nothing for Auto.
export function environmentForStart(pick: string | undefined): string | undefined {
  return pick && pick !== AUTO_ENVIRONMENT ? pick : undefined;
}

/// The `environment` a Cloud send names (App.tsx `sendToCloud`): the start's own, else the chip's
/// pick. Auto names none, and so does any pick while CLOUD_ENVIRONMENTS_ENABLED is off, so the flag
/// off sends exactly what it sent before the chip.
export function cloudStartEnvironment(explicit: string | undefined, pick: string | undefined): string | undefined {
  if (explicit) return explicit;
  return composerSettingsSnapshot().cloudEnvironments ? environmentForStart(pick) : undefined;
}

/// The account's Default environment (Auto's), from `cloud.environment.list`: the personal one.
export function autoEnvironment(environments: readonly CloudEnvironment[]): CloudEnvironmentChoice | undefined {
  const found =
    environments.find((environment) => environment.is_default && environment.scope === "personal") ??
    environments.find((environment) => environment.is_default);
  return found ? { id: found.id, name: found.name } : undefined;
}

/// Where a page keeps each folder's recent environment picks: its `localStorage`.
export type RecentEnvironmentStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
};
const RECENT_KEY = "cmux.cloudEnvironment.recent";
/// Folders remembered at most; the oldest is forgotten first.
const RECENT_FOLDERS = 50;

function pageStore(): RecentEnvironmentStore | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

function readRecent(store: RecentEnvironmentStore | undefined): Record<string, string[]> {
  if (!store) return {};
  try {
    const value = JSON.parse(store.getItem(RECENT_KEY) ?? "{}") as unknown;
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    const kept: Record<string, string[]> = {};
    for (const [folder, ids] of Object.entries(value as Record<string, unknown>))
      if (Array.isArray(ids)) kept[folder] = ids.filter((id): id is string => typeof id === "string");
    return kept;
  } catch {
    return {};
  }
}

/// Remembers `id` as the folder's most recent environment (Auto is never remembered: it is always
/// the first row).
export function rememberEnvironment(
  folder: string | undefined,
  id: string,
  store: RecentEnvironmentStore | undefined = pageStore(),
): void {
  if (!store || id === AUTO_ENVIRONMENT) return;
  const key = folder ?? "";
  const recent = readRecent(store);
  const next = [id, ...(recent[key] ?? []).filter((kept) => kept !== id)].slice(0, RECENT_ENVIRONMENTS * 2);
  delete recent[key];
  const folders = Object.entries(recent).slice(-(RECENT_FOLDERS - 1));
  try {
    store.setItem(RECENT_KEY, JSON.stringify(Object.fromEntries([...folders, [key, next]])));
  } catch {
    // A full or refused store keeps the old list: the picks still go out, only the order is lost.
  }
}

/// The folder's recent environments that the account still lists, most recent first; with none
/// remembered, the account's most recently changed ones. The Default (Auto's) is never listed: Auto
/// is its row.
export function recentEnvironments(
  folder: string | undefined,
  environments: readonly CloudEnvironment[],
  store: RecentEnvironmentStore | undefined = pageStore(),
): CloudEnvironmentChoice[] {
  const others = environments.filter((environment) => !environment.is_default);
  const byId = new Map(others.map((environment) => [environment.id, environment]));
  const remembered = (readRecent(store)[folder ?? ""] ?? [])
    .map((id) => byId.get(id))
    .filter((environment): environment is CloudEnvironment => environment !== undefined);
  const chosen =
    remembered.length > 0
      ? remembered
      : [...others].sort((a, b) => (a.updated_at < b.updated_at ? 1 : a.updated_at > b.updated_at ? -1 : 0));
  return chosen.slice(0, RECENT_ENVIRONMENTS).map(({ id, name }) => ({ id, name }));
}

/// A new chat's pick, held with its run mode (`RunModeRows.environment`): App.tsx keeps it per chat
/// and puts it back to Auto when a chat starts or another new chat shows, so a pick never reaches a
/// later chat's send.
export type CloudEnvironmentPick = { current: string; onPick(id: string): void };

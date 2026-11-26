/// A new Cloud chat's environment (image). The composer has no Environment chip any more
/// (cmux#51731): Settings > Cloud > Default Image (`cloud.defaultImage`) names it, and a chat's start may
/// name its own (chatCloudEnvironment.ts). Behind the launch flag CLOUD_ENVIRONMENTS_ENABLED
/// (composerSettings.ts `cloudEnvironments`).
///
/// - Auto is the default and sends no environment: `cloud.startChat` then boots the chat from the
///   repository's set-up snapshot in the person's Default environment, derived from the chat's
///   folder or repository with no questions (cmux-tui link/start_chat_cli.rs, cmux-platform
///   `POST /v1/environments/derive`).
/// - Any other value is one of the account's Cloud environments (`cloud.environment.list`,
///   cmux-platform `GET /v1/cloud-environments`), sent as `cloud.startChat`'s `environment`.

import type { CloudEnvironment } from "../../pages/cloud/environmentModel";
import { composerSettingsSnapshot } from "./composerSettings";

/// The pick that sends no environment.
export const AUTO_ENVIRONMENT = "auto";
/// One environment: its id and name.
export type CloudEnvironmentChoice = { id: string; name: string };

/// What a Cloud start sends as `environment`: nothing for Auto.
export function environmentForStart(pick: string | undefined): string | undefined {
  return pick && pick !== AUTO_ENVIRONMENT ? pick : undefined;
}

/// The `environment` a Cloud send names (App.tsx `sendToCloud`): the start's own, else the chat's
/// pick. Auto names none, and so does any pick while CLOUD_ENVIRONMENTS_ENABLED is off, so the flag
/// off sends exactly what it sent before the chip.
export function cloudStartEnvironment(explicit: string | undefined, pick: string | undefined): string | undefined {
  if (explicit) return explicit;
  return composerSettingsSnapshot().cloudEnvironments ? environmentForStart(pick) : undefined;
}

/// The Default environment Auto runs in, from `cloud.environment.list`. In a team's context (the list
/// holds the team's environments) it is the team's Default, as the platform's Auto boots a team
/// chat from (cmux-platform `selectedCloudEnvironment`, no id: the record team's Default); else, and
/// for a personal-only account, the personal one. Leo, 2026-11-22 (ask c-922dfe5e36): "we need to be
/// able to make sure arbitrary paying users/teammates can properly use it with the way that we
/// properly use it".
export function autoEnvironment(environments: readonly CloudEnvironment[]): CloudEnvironmentChoice | undefined {
  const found =
    environments.find((environment) => environment.is_default && environment.scope === "team") ??
    environments.find((environment) => environment.is_default && environment.scope === "personal") ??
    environments.find((environment) => environment.is_default);
  return found ? { id: found.id, name: found.name } : undefined;
}

/// What Edit opens while Auto is the pick: in a team's context the team's Default (`autoEnvironment`)
/// by id; else none, so the editor opens the personal Default as it always has.
export function autoEditEnvironment(environments: readonly CloudEnvironment[]): string | undefined {
  return environments.find((environment) => environment.is_default && environment.scope === "team")?.id;
}

/// A new chat's pick, held with its run mode (`RunModeRows.environment`): App.tsx keeps it per chat
/// and puts it back to Auto when a chat starts or another new chat shows, so a pick never reaches a
/// later chat's send.
export type CloudEnvironmentPick = { current: string; onPick(id: string): void };

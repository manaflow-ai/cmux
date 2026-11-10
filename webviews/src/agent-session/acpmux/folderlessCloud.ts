/// A Cloud chat with no folder is a first-class start, not a half state (Leo, 2026-11-09: "We need
/// to be able to have it so, like, this no folder selected should be, like, good as well").
///
/// The page sends such a start with `home: true` (cloudRun.ts `cloudStartFolder`): nothing is copied,
/// and the machine's acpmux runs the chat in a fresh folder of its own, `~/chats/<chat>` (acpmux
/// `server/remote_guard.rs` `peer_scratch`, `cloud_chat_folder_under`): one per chat, owner-only,
/// empty at the start. Not the home folder itself, which holds the machine's state and the copies of
/// other chats' folders (`~/work`). A repository comes later with `/cd` or `cmux chat cd`.
///
/// The folder chip's words for it live here and only here, so the UX lane can restyle them in one
/// place: `FOLDERLESS_CLOUD_LABELS` (keys in Localizable.xcstrings).

import { emptyFolderLabel } from "./composerContextModel";

export const FOLDERLESS_CLOUD_LABELS = {
  /// The chip's face while Cloud is picked and no folder is: a valid state, never "Choose folder".
  label: "composer.cloudNoFolder",
  /// Its one line of detail: in the folder menu, and the chip's accessible description.
  detail: "composer.cloudNoFolderDetail",
} as const;

/// What the folder chip says:
/// - `folder`: a folder is picked (its name);
/// - `newProject`: New Project is the pick;
/// - `noProject`: No folder was picked for a chat on this Mac (its private folder);
/// - `cloudFresh`: Cloud, no folder: the chat starts in a fresh folder on the machine;
/// - `choose`: nothing picked yet: No folder too, a settled choice (composerContextModel.ts
///   emptyFolderLabel), with no Cloud detail.
export type FolderChipState = "folder" | "newProject" | "noProject" | "cloudFresh" | "choose";

/// The chip's words per state but `folder` (which shows the folder's own name).
export const FOLDER_CHIP_LABELS = {
  folder: emptyFolderLabel,
  newProject: "project.new",
  noProject: emptyFolderLabel,
  cloudFresh: FOLDERLESS_CLOUD_LABELS.label,
  choose: emptyFolderLabel,
} as const satisfies Record<FolderChipState, string>;

export function folderChipState({
  folder,
  newProject = false,
  noProject = false,
  cloud,
}: {
  folder: string | undefined;
  newProject?: boolean;
  noProject?: boolean;
  /// Cloud is where the chat runs (picked for a new chat, or the chat's machine is a Cloud one).
  cloud: boolean;
}): FolderChipState {
  if (newProject) return "newProject";
  if (folder) return "folder";
  if (cloud) return "cloudFresh";
  return noProject ? "noProject" : "choose";
}

/// `<home>/chats/<chat>`: a Cloud chat's own fresh folder on its machine, as acpmux makes it.
const CLOUD_CHAT_FOLDER = /^((?:\/home\/[^/]+)|\/root)\/chats\/[^/]+\/*$/;

/// Whether `cwd` is the fresh folder a folderless Cloud chat runs in: the chat has no folder of its
/// own yet, so its chip reads as `cloudFresh`, not as the folder's generated name. Only the path's
/// shape: a caller asks it only of a chat on a Cloud machine (an SSH machine's `~/chats/api` is a
/// project of the person's).
export function isCloudChatFolder(cwd: string | undefined): boolean {
  return cwd !== undefined && CLOUD_CHAT_FOLDER.test(cwd);
}

/// The machine's home folder, read from a folderless Cloud chat's folder (`/home/cmux/chats/x` ->
/// `/home/cmux`); undefined for any other folder. `/cd ~/work/api` in such a chat goes there.
export function cloudChatHome(cwd: string | undefined): string | undefined {
  return cwd === undefined ? undefined : CLOUD_CHAT_FOLDER.exec(cwd)?.[1];
}

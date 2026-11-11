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
import { isAgentHome, projectLabel } from "./sessionList";

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

/// The folder a chat works in, as its chip names it: its cwd, unless that is the chat's own private
/// folder (this Mac's agent home, or a Cloud chat's fresh `~/chats/<chat>`), which reads as the
/// folderless state on both, the way a local chat presents its private folder. `cloud`: the chat's
/// machine is a Cloud one (an SSH machine's `~/chats/api` is a project of the person's).
export function chatOwnFolder(cwd: string | undefined, cloud: boolean): string | undefined {
  if (!cwd || isAgentHome(cwd) || (cloud && isCloudChatFolder(cwd))) return undefined;
  return cwd.replace(/\/+$/, "") || "/";
}

/// The folder chip's face for a chat's own cwd: its state and, for a folder, the folder's name (its
/// last path component, as every chip shows a folder). A Cloud chat on its machine names the folder
/// it works in there (`/home/cmux/work/api` reads "api"), never this Mac's.
export function chatFolderFace(cwd: string | undefined, cloud: boolean): { state: FolderChipState; name?: string } {
  const folder = chatOwnFolder(cwd, cloud);
  const state = folderChipState({ folder, cloud });
  return folder ? { state, name: projectLabel(folder) } : { state };
}

/// What the folder chip opens:
/// - `localFolders`: this Mac's folders and Add folder… (a new chat that starts here, or a Cloud
///   start not sent yet, whose picked folder the start copies to the machine: cloudRun.ts
///   `cloudStartFolder`, `newTabProjectPick`);
/// - `chatFolders`: the folders the chat's own machine has (its sessions' folders and the folder
///   list its host gave for it, `machineFolders`), with Add folder… only on this Mac, whose folder
///   panel lists this Mac's folders;
/// - `label`: no menu, the folder as a plain label: a started chat with nothing to open, or a Cloud
///   start that is out (the folder went with the start; nothing picked now could change it).
export type FolderMenuKind = "localFolders" | "chatFolders" | "label";

export function folderMenu({
  cloudStartOut,
  readOnly,
  newChats,
  onThisMac,
  localChoices,
  cloudMachine,
}: {
  /// A Cloud start this page sent is out (App.tsx `cloudStarting`).
  cloudStartOut: boolean;
  /// The chat's folder is fixed (a started chat, or a surface with no folder pick).
  readOnly: boolean;
  /// A started chat whose folder menu starts a new chat in a folder (`onNewChat`).
  newChats: boolean;
  /// The picked machine is this Mac (the page's own acpmux).
  onThisMac: boolean;
  /// This Mac's folder list was given (`projectChoices`).
  localChoices: boolean;
  /// The chat runs on a Cloud machine, or Cloud is picked for it.
  cloudMachine: boolean;
}): { kind: FolderMenuKind; addFolder: boolean } {
  if (cloudStartOut) return { kind: "label", addFolder: false };
  if (!readOnly && onThisMac && localChoices) return { kind: "localFolders", addFolder: true };
  if (readOnly && !newChats) return { kind: "label", addFolder: false };
  return { kind: "chatFolders", addFolder: newChats && onThisMac && !cloudMachine };
}

/// The folders a `chatFolders` menu lists: the host's list for the chat's machine first (this Mac's
/// `projectChoices` on this Mac, `machineFolders` on the chat's own other machine, none on a machine
/// picked that is neither), then the folders its chats work in. On a Cloud machine, no chat's private
/// `~/chats/<chat>` folder: it is not a folder to pick.
export function chatFolderChoices<F extends { id: string }>({
  known,
  listed,
  cloudMachine,
}: {
  known: readonly F[];
  listed: readonly F[] | undefined;
  cloudMachine: boolean;
}): F[] {
  const merged = listed
    ? (() => {
        const seen = new Set(listed.map((folder) => folder.id));
        return [...listed, ...known.filter((folder) => !seen.has(folder.id))];
      })()
    : [...known];
  return cloudMachine ? merged.filter((folder) => !isCloudChatFolder(folder.id)) : merged;
}

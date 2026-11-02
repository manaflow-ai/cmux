/// Where a new chat runs by default (Labs, cloudRun.ts): from its folder and that folder's history.
/// The folder's newest chat says it. A chat that ran on this Mac in the folder keeps the default on
/// this Mac; a chat that a Cloud start or Move to Cloud put on a Cloud machine from the folder makes
/// it Cloud. A folder with no chats yet runs here, as before. Leo, 2026-10-28: "you can just say ...
/// where should this chat run and stuff, and that's just about it".
///
/// The history is acpmux's own chat list, so it holds across launches with nothing new stored. A
/// chat that went to Cloud from a folder is found by the folder the copy made on the machine: the
/// app copies a folder's checkout (the folder or the nearest one above it holding `.git`) to
/// `<work root>/<name>-<hash>` there, plus the folder's path inside the checkout
/// (CmuxNextCloud CloudMoveFolder `remoteName` and `remote(under:)`, under CloudMoveSetup
/// `workRoots`). The page can't see which folder holds `.git`, so every folder from the chat's up to
/// the disk's root is a candidate; only one is the copy's name.
import { listed, type AcpmuxSessionEntry } from "./sessionList";

export type RunLocation = "local" | "cloud";

/// Where a new chat runs when its composer picks nothing: Cloud when Settings' Start New Chats In
/// (`agentPane.newChatsIn`) says Cloud, else where its folder's newest chat ran (folderRunLocation),
/// else undefined (this Mac, as before). The composer's own pick always wins over this (App.tsx).
export function newChatRunLocation(
  newChatsIn: "local" | "cloud",
  folderDefault: RunLocation | undefined,
): RunLocation | undefined {
  return newChatsIn === "cloud" ? "cloud" : folderDefault;
}

/// The machine's folders for copied folders (CloudMoveSetup `workRoots`), in the app's order.
export const CLOUD_WORK_ROOTS = ["/home/cmux/work", "/root/work"] as const;

/// `path` with `.` and `..` resolved and no trailing slash (CloudMoveFolder `normalized`); undefined
/// for a relative path or one that climbs above the disk's root.
export function normalizedFolder(path: string | undefined): string | undefined {
  if (!path?.startsWith("/")) return undefined;
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (parts.pop() === undefined) return undefined;
      continue;
    }
    parts.push(part);
  }
  return "/" + parts.join("/");
}

/// The copied folder's name on a machine (CloudMoveFolder `remoteName`): the folder's own name and
/// the low 24 bits of the 32-bit FNV-1a hash of its path's UTF-8 bytes, as 6 hex digits.
export function cloudFolderName(root: string): string {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(root)) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  const name = root.split("/").pop() || "folder";
  return `${name}-${(hash & 0xffffff).toString(16).padStart(6, "0")}`;
}

/// Every folder a chat in `folder` could have on a Cloud machine: for each folder from `folder` up
/// (each could be the checkout the app copied), under each work root.
export function cloudFolders(folder: string): Set<string> {
  const paths = new Set<string>();
  const start = normalizedFolder(folder);
  if (!start || start === "/") return paths;
  for (let root = start; root !== "/" && root !== ""; root = root.slice(0, root.lastIndexOf("/")) || "/") {
    const inside = start.slice(root.length);
    for (const work of CLOUD_WORK_ROOTS) paths.add(`${work}/${cloudFolderName(root)}${inside}`);
  }
  return paths;
}

/// A Cloud start's copy goes one level deeper: `<work root>/chats/<send key>/<attempt>/<name>-<hash>`
/// (AgentPaneCloudStart `remotePlace`, CloudStartChat `place`). This is that path with the start's
/// own place taken out, so it reads as a Move to Cloud copy; any other path comes back as it was.
export function withoutStartPlace(cwd: string): string {
  for (const work of CLOUD_WORK_ROOTS) {
    const prefix = `${work}/chats/`;
    if (!cwd.startsWith(prefix)) continue;
    const rest = cwd.slice(prefix.length).split("/");
    // The send key and the attempt, then at least the copied folder's name.
    if (rest.length < 3 || !rest[0] || !rest[1] || !rest[2]) return cwd;
    return `${work}/${rest.slice(2).join("/")}`;
  }
  return cwd;
}

type Peers = Readonly<Record<string, "ssh" | "cloud">> | undefined;

/// Where a chat of the list runs: this Mac, a Cloud machine, or elsewhere (an SSH machine: never
/// this folder's history).
function placeOf(session: AcpmuxSessionEntry, peerKinds: Peers): RunLocation | undefined {
  if (session.hostKind === "cloud") return "cloud";
  if (!session.peer) return "local";
  return peerKinds?.[session.peer] === "cloud" ? "cloud" : undefined;
}

/// When a chat began, for "newest": its creation, else its last activity, else its last write.
const startedAt = (session: AcpmuxSessionEntry) => session.createdAt ?? session.activityAt ?? session.updatedAt ?? 0;

/// Where `folder`'s newest chat ran (undefined: the folder has none, or no folder). Only chats the
/// lists show count (`listed`): a side chat follows its chat, and an archived chat is put away.
export function folderRunLocation(
  folder: string | undefined,
  sessions: readonly AcpmuxSessionEntry[],
  peerKinds?: Peers,
): RunLocation | undefined {
  const local = normalizedFolder(folder);
  if (!local || local === "/") return undefined;
  const remote = cloudFolders(local);
  let newest: { at: number; where: RunLocation } | undefined;
  for (const session of sessions) {
    if (!listed(session)) continue;
    const where = placeOf(session, peerKinds);
    const cwd = normalizedFolder(session.cwd);
    if (!where || !cwd) continue;
    const here = where === "local" ? cwd === local : remote.has(cwd) || remote.has(withoutStartPlace(cwd));
    if (!here) continue;
    const at = startedAt(session);
    if (!newest || at > newest.at) newest = { at, where };
  }
  return newest?.where;
}

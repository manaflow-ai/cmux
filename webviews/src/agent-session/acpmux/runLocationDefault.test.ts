import { expect, test } from "bun:test";
import {
  cloudFolderName,
  cloudFolders,
  folderRunLocation,
  newChatRunLocation,
  normalizedFolder,
  withoutStartPlace,
} from "./runLocationDefault";
import type { AcpmuxSessionEntry } from "./sessionList";

// Expected names computed apart from this code (32-bit FNV-1a over the path's UTF-8 bytes, low 24
// bits), as CloudMoveFolder.remoteName does.
test("a copied folder's name is its own name and the hash of its path", () => {
  expect(cloudFolderName("/Users/me/src/paint")).toBe("paint-33f597");
  expect(cloudFolderName("/Users/me/src")).toBe("src-75be44");
  expect(cloudFolderName("/Users/me/src/café")).toBe("café-717075");
});

test("folders resolve . and .. and drop a trailing slash; relative or escaping ones are none", () => {
  expect(normalizedFolder("/Users/me/src/./paint/")).toBe("/Users/me/src/paint");
  expect(normalizedFolder("/Users/me/x/../src/paint")).toBe("/Users/me/src/paint");
  expect(normalizedFolder("src/paint")).toBeUndefined();
  expect(normalizedFolder("/..")).toBeUndefined();
  expect(normalizedFolder(undefined)).toBeUndefined();
});

test("a folder's places on a machine: the folder or any folder above it as the copy, under each work root", () => {
  const paths = cloudFolders("/Users/me/src/paint");
  expect(paths.has("/home/cmux/work/paint-33f597")).toBe(true);
  expect(paths.has("/root/work/paint-33f597")).toBe(true);
  // The checkout is the folder above: the chat's folder is inside the copy.
  expect(paths.has("/home/cmux/work/src-75be44/paint")).toBe(true);
  expect(paths.has("/home/cmux/work/paint")).toBe(false);
  expect(cloudFolders("/").size).toBe(0);
});

const at = (n: number) => ({ createdAt: n, updatedAt: n });
const local = (cwd: string, n: number): AcpmuxSessionEntry => ({
  sessionId: `l${n}`,
  cwd,
  host: "This Mac",
  hostKind: "local",
  ...at(n),
});
const cloud = (cwd: string, n: number, peer = "cloud-1"): AcpmuxSessionEntry => ({
  sessionId: `c${n}`,
  cwd,
  host: peer,
  hostKind: "cloud",
  peer,
  ...at(n),
});

test("a folder with no chats has no history: the default stays this Mac", () => {
  expect(folderRunLocation("/Users/me/src/paint", [])).toBeUndefined();
  expect(folderRunLocation("/Users/me/src/paint", [local("/Users/me/src/other", 1)])).toBeUndefined();
  expect(folderRunLocation(undefined, [local("/Users/me/src/paint", 1)])).toBeUndefined();
});

test("the folder's newest chat says where: Cloud when it went to a machine from this folder", () => {
  const folder = "/Users/me/src/paint";
  expect(folderRunLocation(folder, [local(folder, 1), cloud("/home/cmux/work/paint-33f597", 2)])).toBe("cloud");
  expect(folderRunLocation(folder, [cloud("/root/work/paint-33f597", 1), local(folder + "/", 2)])).toBe("local");
  // From a folder inside the checkout.
  expect(folderRunLocation(folder, [cloud("/home/cmux/work/src-75be44/paint", 3), local(folder, 2)])).toBe("cloud");
});

test("a Cloud start's copy, under its own chats/<key>/<attempt> place, is this folder's history too", () => {
  const folder = "/Users/me/src/paint";
  const started = "/home/cmux/work/chats/6f1c2a9e-7b1d-4c55-9a0e-2b7f0c1d9e33/a1b2c3d4/paint-33f597";
  expect(withoutStartPlace(started)).toBe("/home/cmux/work/paint-33f597");
  expect(folderRunLocation(folder, [local(folder, 1), cloud(started, 2)])).toBe("cloud");
  // From a folder inside the checkout, under the other work root.
  const inside = "/root/work/chats/k/a1/src-75be44/paint";
  expect(folderRunLocation(folder, [local(folder, 1), cloud(inside, 2)])).toBe("cloud");
  // Another folder's start is not this one's; a short chats/ path is left as it is.
  expect(folderRunLocation(folder, [cloud("/home/cmux/work/chats/k/a1/other-123456", 2)])).toBeUndefined();
  expect(withoutStartPlace("/home/cmux/work/chats/k")).toBe("/home/cmux/work/chats/k");
});

test("another folder's copy, an SSH machine's chat, side chats and archived chats are not this folder's history", () => {
  const folder = "/Users/me/src/paint";
  // Same name, another folder's hash.
  expect(folderRunLocation(folder, [local(folder, 1), cloud("/home/cmux/work/paint-000000", 2)])).toBe("local");
  const ssh: AcpmuxSessionEntry = { sessionId: "s", cwd: folder, peer: "gpu-box", ...at(5) };
  expect(folderRunLocation(folder, [local(folder, 1), ssh], { "gpu-box": "ssh" })).toBe("local");
  const side: AcpmuxSessionEntry = { ...cloud("/home/cmux/work/paint-33f597", 9), side: true };
  expect(folderRunLocation(folder, [local(folder, 1), side])).toBe("local");
  const archived: AcpmuxSessionEntry = { ...cloud("/home/cmux/work/paint-33f597", 9), archived: true };
  expect(folderRunLocation(folder, [local(folder, 1), archived])).toBe("local");
});

test("a peer acpmux names a Cloud peer counts as Cloud without a host kind", () => {
  const folder = "/Users/me/src/paint";
  const peerChat: AcpmuxSessionEntry = { sessionId: "p", cwd: "/home/cmux/work/paint-33f597", peer: "vm-7", ...at(4) };
  expect(folderRunLocation(folder, [local(folder, 1), peerChat], { "vm-7": "cloud" })).toBe("cloud");
});

test("Start New Chats In: Cloud makes every new chat Cloud; This Mac leaves the folder's default", () => {
  expect(newChatRunLocation("cloud", undefined)).toBe("cloud");
  expect(newChatRunLocation("cloud", "local")).toBe("cloud");
  expect(newChatRunLocation("local", undefined)).toBeUndefined();
  expect(newChatRunLocation("local", "cloud")).toBe("cloud");
  expect(newChatRunLocation("local", "local")).toBe("local");
});

import { expect, test } from "bun:test";
import { cloudStartFolder } from "./cloudRun";
import {
  chatFolderChoices,
  chatFolderFace,
  cloudChatHome,
  folderChipState,
  folderMenu,
  isCloudChatFolder,
  startedCloudFolderName,
} from "./folderlessCloud";

test("the folderless rule: a Cloud start with no project folder copies nothing and starts fresh", () => {
  for (const none of [undefined, "", "/", "/Users", "/Users/you", "/home/cmux"])
    expect(cloudStartFolder(none)).toEqual({ home: true });
  expect(cloudStartFolder("/Users/you/src/cmux/")).toEqual({ cwd: "/Users/you/src/cmux" });
});

test("the folder chip: Cloud with no folder is cloudFresh, never an empty Choose folder", () => {
  expect(folderChipState({ folder: undefined, cloud: true })).toBe("cloudFresh");
  expect(folderChipState({ folder: undefined, cloud: true, noProject: true })).toBe("cloudFresh");
  expect(folderChipState({ folder: undefined, cloud: false })).toBe("choose");
  expect(folderChipState({ folder: undefined, cloud: false, noProject: true })).toBe("noProject");
  expect(folderChipState({ folder: "/Users/you/src/cmux", cloud: true })).toBe("folder");
  expect(folderChipState({ folder: undefined, cloud: true, newProject: true })).toBe("newProject");
});

test("a Cloud chat's fresh folder, and the machine home it names", () => {
  expect(isCloudChatFolder("/home/cmux/chats/peer-12")).toBe(true);
  expect(isCloudChatFolder("/root/chats/s-1/")).toBe(true);
  expect(isCloudChatFolder("/home/cmux/chats/s-1/api")).toBe(false);
  expect(isCloudChatFolder("/home/cmux/work/api")).toBe(false);
  expect(isCloudChatFolder("/Users/you/chats/x")).toBe(false);
  expect(isCloudChatFolder(undefined)).toBe(false);
  expect(cloudChatHome("/home/cmux/chats/peer-12")).toBe("/home/cmux");
  expect(cloudChatHome("/root/chats/s-1")).toBe("/root");
  expect(cloudChatHome("/Users/you/src")).toBeUndefined();
});

test("a Cloud chat's chip names the folder it works in on its machine, as a local chat's does", () => {
  expect(chatFolderFace("/home/cmux/work/api", true)).toEqual({ state: "folder", name: "api" });
  expect(chatFolderFace("/home/cmux/work/api/", true)).toEqual({ state: "folder", name: "api" });
  expect(chatFolderFace("/Users/you/src/cmux", false)).toEqual({ state: "folder", name: "cmux" });
  // The chat's own fresh folder reads as the folderless state, as a local chat's private folder does.
  expect(chatFolderFace("/home/cmux/chats/s-1", true)).toEqual({ state: "cloudFresh" });
  // On an SSH machine `~/chats/api` is a project like any other.
  expect(chatFolderFace("/home/cmux/chats/api", false)).toEqual({ state: "folder", name: "api" });
});

test("a started Cloud chat in its machine's fresh folder names that folder, never No folder", () => {
  const on = { cloud: true, started: true };
  expect(startedCloudFolderName("/home/cmux/chats/s-1", on)).toBe("s-1");
  expect(startedCloudFolderName("/root/chats/peer-12/", on)).toBe("peer-12");
  // Not sent yet: No folder is the valid start. Any other folder: the chip names it itself.
  expect(startedCloudFolderName("/home/cmux/chats/s-1", { cloud: true, started: false })).toBeUndefined();
  expect(startedCloudFolderName("/home/cmux/work/api", on)).toBeUndefined();
  expect(startedCloudFolderName("/home/cmux/chats/api", { cloud: false, started: true })).toBeUndefined();
  expect(startedCloudFolderName(undefined, on)).toBeUndefined();
});

const started = { cloudStartOut: false, readOnly: true, onThisMac: false, localChoices: true };

test("a started Cloud chat's folder menu: its machine's folders only, never Add folder…", () => {
  // `newChats` false (a Cloud chat cannot start one in a Mac tab) or true: never this Mac's list.
  for (const newChats of [false, true]) {
    const menu = folderMenu({ ...started, newChats, cloudMachine: true });
    expect(menu.kind).not.toBe("localFolders");
    expect(menu.addFolder).toBe(false);
  }
  // An unsent chat already on its Cloud machine (its page's own acpmux is the machine's).
  expect(folderMenu({ ...started, readOnly: false, newChats: false, cloudMachine: true })).toEqual({
    kind: "chatFolders",
    addFolder: false,
  });
  const machine = [{ id: "/home/cmux/work/api" }, { id: "/home/cmux/chats/other-chat" }, { id: "/home/cmux/work/web" }];
  expect(
    chatFolderChoices({ known: machine, listed: [{ id: "/home/cmux/work/web" }], cloudMachine: true }).map((f) => f.id),
  ).toEqual(["/home/cmux/work/web", "/home/cmux/work/api"]);
});

test("a Cloud start not sent yet keeps this Mac's folders (the start copies the pick); once out, a label", () => {
  const preStart = { readOnly: false, newChats: false, onThisMac: true, localChoices: true, cloudMachine: true };
  expect(folderMenu({ ...preStart, cloudStartOut: false })).toEqual({ kind: "localFolders", addFolder: true });
  expect(folderMenu({ ...preStart, cloudStartOut: true })).toEqual({ kind: "label", addFolder: false });
  // A started chat on this Mac keeps Add folder… (a new chat in a folder this Mac's panel picks).
  expect(
    folderMenu({
      cloudStartOut: false,
      readOnly: true,
      newChats: true,
      onThisMac: true,
      localChoices: true,
      cloudMachine: false,
    }),
  ).toEqual({ kind: "chatFolders", addFolder: true });
});

// A new chat's extra folders (acpmux `additionalDirectories`): what the composer adds and removes,
// and what goes in `session/new`.
import { describe, expect, test } from "bun:test";
import {
  MAX_EXTRA_FOLDERS,
  addExtraFolder,
  draftFolders,
  extraFolderName,
  extraFoldersParam,
  ownMachineFolders,
  removeExtraFolder,
  summaryExtraFolders,
} from "./extraFolders";

describe("addExtraFolder", () => {
  test("adds an absolute folder once, without its trailing slash", () => {
    const one = addExtraFolder([], "/Users/you/notes/");
    expect(one).toEqual(["/Users/you/notes"]);
    expect(addExtraFolder(one, "/Users/you/notes")).toBe(one);
    expect(addExtraFolder(one, "/Users/you/data")).toEqual(["/Users/you/notes", "/Users/you/data"]);
  });
  test("never the chat's own folder, a relative path, `/` or a home-relative path", () => {
    expect(addExtraFolder([], "/src/cmux", "/src/cmux/")).toEqual([]);
    expect(addExtraFolder([], "notes")).toEqual([]);
    expect(addExtraFolder([], "/")).toEqual([]);
    expect(addExtraFolder([], "~/notes")).toEqual([]);
    expect(addExtraFolder([], "/a\0b")).toEqual([]);
  });
  test(`at most ${MAX_EXTRA_FOLDERS}, as acpmux takes`, () => {
    let folders: readonly string[] = [];
    for (let index = 0; index < MAX_EXTRA_FOLDERS + 3; index += 1) folders = addExtraFolder(folders, `/f/${index}`);
    expect(folders.length).toBe(MAX_EXTRA_FOLDERS);
  });
});

test("removeExtraFolder drops one, and keeps the list when it was not there", () => {
  const folders = ["/a", "/b"];
  expect(removeExtraFolder(folders, "/a/")).toEqual(["/b"]);
  expect(removeExtraFolder(folders, "/c")).toBe(folders);
});

test("draftFolders are the picked machine's only", () => {
  const draft = { machine: "devbox", folders: ["/srv/data"] };
  expect(draftFolders(draft, "devbox")).toEqual(["/srv/data"]);
  expect(draftFolders(draft, "local")).toEqual([]);
  expect(draftFolders(undefined, "local")).toEqual([]);
});

describe("extraFoldersParam", () => {
  test("none: the field is left out", () => {
    expect(extraFoldersParam(undefined)).toBeUndefined();
    expect(extraFoldersParam([])).toBeUndefined();
    expect(extraFoldersParam(["/src/cmux"], "/src/cmux")).toBeUndefined();
  });
  test("the folders other than the chat's own, each once", () => {
    expect(extraFoldersParam(["/a", "/src/cmux", "/a/", "/b"], "/src/cmux")).toEqual(["/a", "/b"]);
    // With no project the chat's private folder is its cwd; every folder goes beside it.
    expect(extraFoldersParam(["/a", "/b"])).toEqual(["/a", "/b"]);
  });
});

test("summaryExtraFolders reads acpmux's list and keeps its identity", () => {
  const listed = ["/a", "/b"];
  expect(summaryExtraFolders(listed)).toBe(listed);
  expect(summaryExtraFolders(["/a", 3, ""])).toEqual(["/a"]);
  expect(summaryExtraFolders([])).toBeUndefined();
  expect(summaryExtraFolders("/a")).toBeUndefined();
  expect(summaryExtraFolders(undefined)).toBeUndefined();
});

test("extraFolderName is the last path component", () => {
  expect(extraFolderName("/Users/you/notes/")).toBe("notes");
  expect(extraFolderName("/data set")).toBe("data set");
});

test("ownMachineFolders: a Cloud pane's own folders are local to its client", () => {
  const draft = { machine: "zesty-box", folders: ["/home/you/data"] };
  expect(ownMachineFolders(draft, "zesty-box")).toEqual({ machine: "local", folders: ["/home/you/data"] });
  expect(ownMachineFolders(draft, "local")).toBe(draft);
  expect(ownMachineFolders(undefined, "zesty-box")).toBeUndefined();
});

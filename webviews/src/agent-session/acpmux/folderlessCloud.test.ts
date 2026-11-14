import { expect, test } from "bun:test";
import { cloudStartFolder } from "./cloudRun";
import { cloudChatHome, folderChipState, isCloudChatFolder } from "./folderlessCloud";

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

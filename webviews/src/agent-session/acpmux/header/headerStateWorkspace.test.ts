import { afterEach, expect, test } from "bun:test";
import { headerState, resetHeaderStateForTests, setHeaderState } from "./headerState";

afterEach(() => resetHeaderStateForTests());

test("the chat's workspace and its chat count come with the App's header state", () => {
  expect(headerState().workspace).toBeUndefined();
  setHeaderState({ workspace: { title: "cmux", chats: 3 }, version: 1 });
  expect(headerState().workspace).toEqual({ title: "cmux", chats: 3 });
});

test("a push without the workspace keeps it, and null clears it", () => {
  setHeaderState({ workspace: { title: "cmux", chats: 2 }, version: 1 });
  setHeaderState({ pinned: true, version: 2 });
  expect(headerState().workspace).toEqual({ title: "cmux", chats: 2 });
  setHeaderState({ workspace: null, version: 3 });
  expect(headerState().workspace).toBeUndefined();
});

test("a workspace without a string title is none, and a bad count reads 0", () => {
  setHeaderState({ workspace: { chats: 2 }, version: 1 });
  expect(headerState().workspace).toBeUndefined();
  setHeaderState({ workspace: ["cmux", 2], version: 2 });
  expect(headerState().workspace).toBeUndefined();
  setHeaderState({ workspace: { title: "docs", chats: "4" }, version: 3 });
  expect(headerState().workspace).toEqual({ title: "docs", chats: 0 });
  setHeaderState({ workspace: { title: "docs", chats: -1.5 }, version: 4 });
  expect(headerState().workspace).toEqual({ title: "docs", chats: 0 });
});

test("an older reply does not bring back a workspace a newer push changed", () => {
  setHeaderState({ workspace: { title: "renamed", chats: 1 }, version: 5 });
  setHeaderState({ workspace: { title: "old", chats: 1 }, version: 4 });
  expect(headerState().workspace?.title).toBe("renamed");
});

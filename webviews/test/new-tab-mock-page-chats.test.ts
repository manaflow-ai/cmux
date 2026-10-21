// A New Tab page on the in-page mock daemon (a tour or a demo inside the app) lists its own mock
// chats, never the app's shared chat store, though the mock names itself local (#22115 review).
import { afterAll, expect, test } from "bun:test";
import { markMockPage, sharesChatList } from "../src/agent-session/acpmux/newtab/chatStore";

afterAll(() => markMockPage(false));

test("a mock daemon's New Tab page does not list the shared chats", () => {
  const snapshot = { origin: "local" as const, connection: "connected" };
  expect(sharesChatList({}, snapshot)).toBe(true);
  markMockPage();
  expect(sharesChatList({}, snapshot)).toBe(false);
});

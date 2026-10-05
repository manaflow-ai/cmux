import { expect, test } from "bun:test";
import { newTabScreenActions } from "./screenActions";

test("the selected project replaces the inherited folder for chat and terminal", async () => {
  const calls: unknown[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => { calls.push([method, params]); },
    cwd: "/src/old", leave() {}, selectSession() {}, showAllChats() {},
  });
  actions.onAsk("codex", "hello", "/src/new");
  actions.onTerminal("git status", "/src/new");
  await Promise.resolve();
  expect(calls).toContainEqual(["chat.new", { harness: "codex", cwd: "/src/new" }]);
  expect(calls).toContainEqual(["tab.open", { kind: "terminal", text: "git status", run: false, cwd: "/src/new" }]);
});

test("a local file uses the file opener and a URL uses the browser", () => {
  const calls: unknown[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => { calls.push([method, params]); },
    leave() {}, selectSession() {}, showAllChats() {},
  });
  actions.onOpen("file:///src/my%20file.md");
  actions.onOpen("https://example.com");
  expect(calls).toEqual([
    ["file.open", { path: "/src/my file.md", where: "tab" }],
    ["tab.open", { kind: "browser", text: "https://example.com" }],
  ]);
});

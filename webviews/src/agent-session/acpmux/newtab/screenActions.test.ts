import { expect, test } from "bun:test";
import { newTabScreenActions } from "./screenActions";

test("the page's chat and terminal start in the folder the tab inherited", async () => {
  const calls: unknown[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push([method, params]);
    },
    cwd: "/src/old",
    leave() {},
    selectSession() {},
    showAllChats() {},
  });
  actions.onAsk("codex", "hello");
  actions.onTerminal("git status");
  await Promise.resolve();
  expect(calls).toContainEqual(["chat.new", { harness: "codex", cwd: "/src/old" }]);
  expect(calls).toContainEqual(["tab.open", { kind: "terminal", text: "git status", run: false, cwd: "/src/old" }]);
});

test("a local file uses the file opener and a URL uses the browser", () => {
  const calls: unknown[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push([method, params]);
    },
    leave() {},
    selectSession() {},
    showAllChats() {},
  });
  actions.onOpen("file:///src/my%20file.md");
  actions.onOpen("https://example.com");
  expect(calls).toEqual([
    ["file.open", { path: "/src/my file.md", where: "tab" }],
    ["tab.open", { kind: "browser", text: "https://example.com" }],
  ]);
});

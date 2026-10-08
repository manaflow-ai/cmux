import { expect, test } from "bun:test";
import { newTabScreenActions } from "./screenActions";

test("the page's chat and shell command start in the folder the tab inherited", async () => {
  const calls: unknown[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push([method, params]);
    },
    cwd: "/src/old",
    leave: () => calls.push(["leave"]),
    selectSession() {},
    showAllChats() {},
    runShell: (command, cwd) => calls.push(["runShell", command, cwd]),
  });
  actions.onAsk("codex", "hello");
  actions.onShell("git status");
  await Promise.resolve();
  expect(calls).toContainEqual(["chat.new", { harness: "codex", cwd: "/src/old" }]);
  // `!cmd` leaves for a terminal tab that runs it in the inherited folder.
  expect(calls).toContainEqual(["tab.open", { kind: "terminal", text: "git status", run: true, cwd: "/src/old" }]);
  expect(calls.some((call) => (call as unknown[])[0] === "runShell")).toBe(false);
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
    runShell() {},
  });
  actions.onOpen("file:///src/my%20file.md");
  actions.onOpen("https://example.com");
  expect(calls).toEqual([
    ["file.open", { path: "/src/my file.md", where: "tab" }],
    ["tab.open", { kind: "browser", text: "https://example.com" }],
  ]);
});

import { expect, test } from "bun:test";
import { newTabScreenActions } from "./screenActions";

test("the selected project replaces the inherited folder for chat and shell command", async () => {
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
  actions.onAsk("codex", "hello", "/src/new");
  actions.onShell("git status", "/src/new");
  actions.onShell("ls");
  await Promise.resolve();
  expect(calls).toContainEqual(["chat.new", { harness: "codex", cwd: "/src/new" }]);
  // `!cmd` leaves for a chat that runs it; no terminal tab replaces the page.
  expect(calls).toContainEqual(["runShell", "git status", "/src/new"]);
  expect(calls).toContainEqual(["runShell", "ls", "/src/old"]);
  expect(calls.some((call) => (call as unknown[])[0] === "tab.open")).toBe(false);
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

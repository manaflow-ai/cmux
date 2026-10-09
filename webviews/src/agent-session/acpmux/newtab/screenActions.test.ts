import { expect, test } from "bun:test";
import { newTabScreenActions } from "./screenActions";

test("the page's chat and shell command start in the folder the tab inherited", async () => {
  const calls: unknown[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push([method, params]);
    },
    cwd: "/src/old",
    // The host names a project folder as the chat's start folder too.
    chatCwd: "/src/old",
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

// cx-nn3e: a fresh workspace's New Tab page sits at `~`. Its agent row started the chat in `~`
// (chip `~`, then "This folder is outside the folders this pane may use" and a Retry) while the
// line above the composer said the chat starts in a private folder. A chat starts in the folder
// the host named for it (`chatCwd`), never in the page's inherited folder; a terminal still does.
test("the page's chat starts in the host's chat folder, not the inherited home folder", async () => {
  const calls: unknown[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push([method, params]);
    },
    cwd: "/Users/me",
    chatCwd: undefined,
    leave() {},
    selectSession() {},
    showAllChats() {},
    runShell() {},
  });
  actions.onAsk("claude", "hello");
  actions.onShell("ls");
  await Promise.resolve();
  expect(calls).toContainEqual(["chat.new", { harness: "claude" }]);
  expect(calls).toContainEqual(["tab.open", { kind: "terminal", text: "ls", run: true, cwd: "/Users/me" }]);
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

// cx-e2aa: the project picked at the top of the page wins over the folder the tab inherited.
test("a prompt asks in the project picked on the page", async () => {
  const calls: unknown[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push([method, params]);
    },
    cwd: "/src/old",
    leave() {},
    selectSession() {},
    showAllChats() {},
    runShell() {},
  });
  actions.onAsk("codex", "hello", "/src/picked");
  await Promise.resolve();
  expect(calls).toContainEqual(["chat.new", { harness: "codex", cwd: "/src/picked" }]);
});

test("a device chat card leaves the new tab and opens through the host's shared Open Chat path", () => {
  const calls: unknown[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push([method, params]);
    },
    leave: () => calls.push(["leave"]),
    selectSession() {},
    showAllChats() {},
    runShell() {},
  });
  actions.onOpenChat?.("codex:01999a2b");
  expect(calls).toEqual([["leave"], ["chats.open", { key: "codex:01999a2b" }]]);
});

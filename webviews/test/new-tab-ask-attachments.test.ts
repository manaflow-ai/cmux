// Leo, 2026-10-19: images pasted on the New Tab page must go with the chat's first prompt. The page's
// ask (screenActions onAsk) starts the chat and sends the prompt with its attachments, or the
// attachments alone; a plain prompt sends as before.
import { expect, test } from "bun:test";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { newTabScreenActions } from "../src/agent-session/acpmux/newtab/screenActions";

const noop = () => {};
const image: ComposerAttachment = {
  id: "a1",
  kind: "image",
  name: "Screenshot.png",
  mimeType: "image/png",
  size: 4,
  data: "iVBO",
};

function actions() {
  const sent: [string, unknown][] = [];
  const screen = newTabScreenActions({
    callNative: async (method, params) => {
      sent.push([method, params]);
      return method === "chat.new" ? "session-1" : undefined;
    },
    chatCwd: "/Users/you/src/app",
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  return { screen, sent };
}

test("the first prompt carries the attachments pasted on the page", () => {
  const { screen, sent } = actions();
  screen.onAsk("claude", "what is this", undefined, undefined, undefined, [image]);
  expect(sent.map(([method]) => method)).toEqual(["newTab.remember", "chat.new", "chat.send"]);
  expect(sent[2]![1]).toEqual({ text: "what is this", attachments: [image] });
});

test("attachments alone start the chat with them", () => {
  const { screen, sent } = actions();
  screen.onAsk("claude", "", undefined, undefined, undefined, [image]);
  expect(sent.find(([method]) => method === "chat.send")?.[1]).toEqual({ text: "", attachments: [image] });
});

test("a prompt with no attachments sends only its text, and an empty one sends nothing", () => {
  const plain = actions();
  plain.screen.onAsk("claude", "hi");
  expect(plain.sent.find(([method]) => method === "chat.send")?.[1]).toEqual({ text: "hi" });
  const empty = actions();
  empty.screen.onAsk("claude", "");
  expect(empty.sent.some(([method]) => method === "chat.send")).toBe(false);
});

test("keeps the New Tab visible until its folder and chat start are accepted", async () => {
  let leaves = 0;
  let acceptFolder: ((folder: string) => void) | undefined;
  const screen = newTabScreenActions({
    callNative: async () => "session-1",
    cwd: "/Users/you/src/app",
    chatCwd: "/Users/you/src/app",
    leave: () => {
      leaves += 1;
    },
    requestFolder: (_cwd, start) => {
      acceptFolder = start;
    },
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });

  const starting = screen.onAsk("claude", "start in the picked folder", "/Users/you/src/other");
  expect(leaves).toBe(0);
  expect(acceptFolder).toBeDefined();
  acceptFolder!("/Users/you/src/other");
  expect(leaves).toBe(0);
  await starting;
  expect(leaves).toBe(1);
});

test("a refused folder start settles instead of leaving the submit pending", async () => {
  const { pickFolder } = await import("../src/agent-session/acpmux/startFolder");
  const native = async () => {
    throw Object.assign(new Error("not a folder"), { code: "transport.path_invalid" });
  };
  const screen = newTabScreenActions({
    callNative: native,
    requestFolder: (cwd, start, cancel) => {
      void pickFolder(native, cwd, start, cancel);
    },
    leave: () => {},
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
  });
  await expect(Promise.resolve(screen.onAsk("claude", "keep me", "/invalid/project"))).rejects.toThrow();
});

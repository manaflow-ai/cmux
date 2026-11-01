// Leo, 2026-10-19: images pasted on the New Tab page must go with the chat's first prompt. The page's
// ask (screenActions onAsk) starts the chat and sends the prompt with its attachments, or the
// attachments alone; a plain prompt sends as before.
import { expect, jest, test } from "bun:test";
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

// The switch's queue holds the prompt as the chat's first row from the moment it is sent, so the
// page becomes that chat once the folder is accepted, not after the start (Leo 2026-10-30: "I
// SHOULD BE ALWAYS ABLE TO SATRT NEW FUCKGN CHATS").
test("keeps the New Tab visible until its folder is accepted, then becomes the chat", async () => {
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
  expect(leaves).toBe(1);
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

// A busy Mac: acpmux took a minute and a half to give the harness a session ("pooled session failed
// to start: no harness session within 90s"), and the New Tab sat on the typed prompt the whole time
// (Leo 2026-10-30: "I TSHOULDN'T FUCKING MATTER IF MY COMPUTER IS LOADED"). The page becomes the chat
// at once with the prompt queued in it, and the prompt goes once the start answers.
test("a start that takes two minutes opens the chat at once with the prompt queued", async () => {
  jest.useFakeTimers();
  try {
    const sent: string[] = [];
    let leaves = 0;
    let delivered = false;
    const screen = newTabScreenActions({
      callNative: (method) => {
        sent.push(method);
        // fixed-wait: fake timers stand in for a two-minute start; nothing waits on the wall clock.
        if (method === "chat.new") return new Promise((resolve) => setTimeout(() => resolve("session-1"), 120_000));
        // The switch's queue sends the held prompt once its session is up (harnessSwitch.ts).
        if (method === "chat.send")
          // fixed-wait: fake timers stand in for the queued prompt's delivery.
          return new Promise((resolve) =>
            setTimeout(() => {
              delivered = true;
              resolve(undefined);
            }, 120_000),
          );
        return Promise.resolve(undefined);
      },
      chatCwd: "/Users/you/src/app",
      leave: () => {
        leaves += 1;
      },
      selectSession: noop,
      showAllChats: noop,
      runShell: noop,
    });
    let settled = false;
    void Promise.resolve(screen.onAsk("claude", "helo")).then(() => (settled = true));
    expect(leaves).toBe(1);
    expect(sent).toEqual(["newTab.remember", "chat.new", "chat.send"]);
    jest.advanceTimersByTime(119_999);
    await Promise.resolve();
    expect(delivered).toBe(false);
    expect(settled).toBe(false);
    jest.advanceTimersByTime(1);
    for (let turn = 0; turn < 5; turn++) await Promise.resolve();
    expect(delivered).toBe(true);
    expect(settled).toBe(true);
    expect(leaves).toBe(1);
  } finally {
    jest.useRealTimers();
  }
});

// New chat with nothing typed has no prompt to hold, so it still becomes the chat once it started.
test("an empty New chat becomes the chat once its start answers", async () => {
  let leaves = 0;
  let finish!: (session: string) => void;
  const screen = newTabScreenActions({
    callNative: (method) =>
      method === "chat.new" ? new Promise((resolve) => (finish = resolve)) : Promise.resolve(undefined),
    chatCwd: "/Users/you/src/app",
    leave: () => {
      leaves += 1;
    },
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  const started = Promise.resolve(screen.onAsk("claude", ""));
  expect(leaves).toBe(0);
  finish("session-1");
  await started;
  expect(leaves).toBe(1);
});

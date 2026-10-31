import { expect, test } from "bun:test";
import { newTabScreenActions } from "./screenActions";

test("a cancelled folder confirmation calls back without opening or sending a chat", async () => {
  const methods: string[] = [];
  const folders: string[] = [];
  let left = 0;
  let cancelled = 0;
  let useFolder: ((folder: string) => void) | undefined;
  let cancelFolder: (() => void) | undefined;
  const actions = newTabScreenActions({
    callNative: async (method) => {
      methods.push(method);
      return "chat-1";
    },
    cwd: "/synthetic/base",
    chatCwd: "/synthetic/base",
    leave: () => {
      left += 1;
    },
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
    requestFolder: (cwd, use, cancel) => {
      folders.push(cwd);
      useFolder = use;
      cancelFolder = cancel;
    },
  });

  const ask = () =>
    actions.onAsk(
      "claude",
      "Keep this draft",
      "/synthetic/new",
      undefined,
      undefined,
      undefined,
      undefined,
      () => {
        cancelled += 1;
      },
    );
  ask();
  expect(folders).toEqual(["/synthetic/new"]);
  expect(typeof cancelFolder).toBe("function");
  cancelFolder!();
  expect(cancelled).toBe(1);
  expect(left).toBe(0);
  expect(methods).not.toContain("chat.new");
  expect(methods).not.toContain("chat.send");

  ask();
  expect(folders).toEqual(["/synthetic/new", "/synthetic/new"]);
  useFolder!("/synthetic/new");
  expect(left).toBe(1);
  await Promise.resolve();
  expect(methods).toContain("chat.new");
  expect(methods).toContain("chat.send");
});

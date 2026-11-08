import { expect, test } from "bun:test";
import { newTabScreenActions } from "./screenActions";

test("fix-from-link selects the created chat before leaving New Tab", async () => {
  const calls: string[] = [];
  const actions = newTabScreenActions({
    callNative: async (method) => {
      calls.push(method);
      return { sessionId: "session-fix-12" };
    },
    leave: () => calls.push("leave"),
    selectSession: (sessionId) => calls.push(`select:${sessionId}`),
    showAllChats: () => {},
    runShell: () => {},
  });

  actions.onFixFromLink?.("https://github.com/acme/widget/issues/12");
  await Promise.resolve();
  await Promise.resolve();

  expect(calls).toEqual(["chat.fix_from_link", "leave", "select:session-fix-12"]);
});

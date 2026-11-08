import { expect, test } from "bun:test";
import { newTabScreenActions } from "./screenActions";

test("fix-from-link selects the created chat while New Tab stays mounted", async () => {
  const calls: string[] = [];
  let params: Record<string, unknown> | undefined;
  const actions = newTabScreenActions({
    callNative: async (method, next) => {
      calls.push(method);
      params = next;
      return { sessionId: "session-fix-12" };
    },
    cwd: "/tmp/widget",
    leave: () => calls.push("leave"),
    selectSession: (sessionId) => calls.push(`select:${sessionId}`),
    showAllChats: () => {},
    runShell: () => {},
  });

  actions.onFixFromLink?.("https://github.com/acme/widget/issues/12");
  await Promise.resolve();
  await Promise.resolve();

  expect(calls).toEqual(["chat.fix_from_link", "select:session-fix-12"]);
  expect(params).toEqual({ url: "https://github.com/acme/widget/issues/12", cwd: "/tmp/widget" });
});

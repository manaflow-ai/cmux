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

  await actions.onFixFromLink?.("https://github.com/acme/widget/issues/12");

  expect(calls).toEqual(["chat.fix_from_link", "select:session-fix-12"]);
  expect(params).toEqual({ url: "https://github.com/acme/widget/issues/12" });
});

test("fix-from-link sends the project picked on the page", async () => {
  let params: Record<string, unknown> | undefined;
  const actions = newTabScreenActions({
    callNative: async (_method, next) => {
      params = next;
      return { sessionId: "session-fix-picked" };
    },
    cwd: "/tmp/inherited",
    leave: () => {},
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
  });

  await actions.onFixFromLink?.("https://github.com/acme/widget/issues/13", "/tmp/picked-checkout");

  expect(params).toEqual({ url: "https://github.com/acme/widget/issues/13", cwd: "/tmp/picked-checkout" });
});

test("fix-from-link carries the selected harness and model", async () => {
  let params: Record<string, unknown> | undefined;
  const actions = newTabScreenActions({
    callNative: async (_method, next) => {
      params = next;
      return { sessionId: "session-fix-picked-agent" };
    },
    cwd: "/tmp/widget",
    leave: () => {},
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
  });

  await actions.onFixFromLink?.("https://github.com/acme/widget/issues/14", "/tmp/widget", "codex", "gpt-6-astra");

  expect(params).toEqual({
    url: "https://github.com/acme/widget/issues/14",
    cwd: "/tmp/widget",
    harness: "codex",
    model: "gpt-6-astra",
  });
});

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

test("every pick from the field opens in the page's tab, never a split; Option-Return opens beside", () => {
  const opens: Record<string, unknown>[] = [];
  let left = 0;
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      if (method === "tab.open") opens.push(params!);
      return undefined;
    },
    cwd: "/tmp/widget",
    leave: () => void left++,
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
  });
  actions.onShell("git status");
  // The page stays until the host closes it under the new tab: a refused open keeps the text.
  expect(left).toBe(0);
  actions.onOpen("https://example.com/");
  actions.onSearch("cmux docs");
  actions.onOpenInProfile?.("https://example.com/", "work");
  actions.onOpenInNewProfile?.("https://example.com/", "Work");
  expect(opens).toEqual([
    { kind: "terminal", text: "git status", run: true, inPlace: true, cwd: "/tmp/widget" },
    { kind: "browser", text: "https://example.com/", inPlace: true },
    { kind: "browser", text: "cmux docs", search: true, inPlace: true },
    { kind: "browser", text: "https://example.com/", profile: "work", inPlace: true },
    { kind: "browser", text: "https://example.com/", newProfile: true, inPlace: true, profileName: "Work" },
  ]);
  opens.length = 0;
  actions.onOpen("https://example.com/", { beside: true });
  actions.onSearch("cmux docs", { beside: true });
  expect(opens).toEqual([
    { kind: "browser", text: "https://example.com/", beside: true },
    { kind: "browser", text: "cmux docs", search: true, beside: true },
  ]);
});

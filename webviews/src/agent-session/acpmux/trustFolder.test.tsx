import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  // The composer's prompt is a Milkdown (ProseMirror) editor.
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { TrustAsk } = await import("./TrustAsk");
const { useFolderTrustAsk } = await import("./useFolderTrustAsk");
const { readFolderTrust, readTrust, stricterTrust } = await import("./folderTrust");
const { MockAcpmuxSocket } = await import("./mock");
type TrustLevel = import("./folderTrust").TrustLevel;

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
const row = () => doc.querySelector(".acpmux-trust-ask");
// The trust read and save each resolve over a couple of ticks.
const settled = async () => {
  await settle();
  await settle();
};
const press = async (label: string) => {
  await act(async () =>
    [...doc.querySelectorAll<HTMLButtonElement>(".acpmux-trust-ask-action")]
      .find((button) => button.textContent === label)!
      .click(),
  );
  await settled();
};

/// The hook as App drives it, over a folder whose acpmux record `levels` holds.
function Harness({
  levels,
  chat,
  fail,
}: {
  levels: Map<string, TrustLevel>;
  chat: { sessionId?: string; cwd?: string; started: boolean; turns: number };
  fail?: boolean;
}) {
  const source = React.useMemo(
    () => ({
      get: async (cwd: string) => ({ cwd, level: levels.get(cwd) ?? "unknown" }),
      set: async (cwd: string, level: TrustLevel) => {
        if (fail) throw new Error("host gone");
        if (level === "unknown") levels.delete(cwd);
        else levels.set(cwd, level);
        return { cwd, level };
      },
    }),
    [levels, fail],
  );
  const trust = useFolderTrustAsk(source, chat);
  return trust.ask
    ? createElement(TrustAsk, {
        ask: trust.ask,
        agent: "Claude Code",
        onTrust: trust.trust,
        onDistrust: trust.distrust,
        onUndo: trust.undo,
      })
    : null;
}
const React = await import("react");
const render = async (props: Parameters<typeof Harness>[0]) => {
  await act(async () => root.render(createElement(Harness, props)));
  await settled();
};

test("a trust reply reads as its folder and level, and a host that can't say reads as nothing", async () => {
  expect(readTrust({ cwd: "/a", level: "trusted" })).toEqual({ cwd: "/a", level: "trusted" });
  expect(
    readTrust({ cwd: "/a", level: "unknown", harnesses: { claude: "unknown", codex: "trusted", other: "x" } }),
  ).toEqual({ cwd: "/a", level: "unknown", harnesses: { claude: "unknown", codex: "trusted" } });
  expect(stricterTrust("trusted", "unknown")).toBe("unknown");
  expect(stricterTrust("unknown", "untrusted")).toBe("untrusted");
  expect(stricterTrust("trusted", "trusted")).toBe("trusted");
  expect(readTrust({ cwd: "/a", level: "maybe" })).toBeUndefined();
  expect(readTrust(null)).toBeUndefined();
  const source = (level: unknown) => ({ get: async (cwd: string) => ({ cwd, level }), set: async () => ({}) });
  expect((await readFolderTrust(source("unknown"), "/a"))?.level).toBe("unknown");
  expect(
    await readFolderTrust({ get: () => Promise.reject(new Error("no such method")), set: async () => ({}) }, "/a"),
  ).toBeUndefined();
  expect(await readFolderTrust({ get: async () => ({}), set: async () => ({}) }, "/a")).toBeUndefined();
  // A host that never answers leaves the folder unasked once the wait runs out.
  expect(await readFolderTrust({ get: () => new Promise(() => {}), set: async () => ({}) }, "/a", 10)).toBeUndefined();
});

test("a new chat's folder is asked about only after its first prompt, and nothing waits on it", async () => {
  const levels = new Map<string, TrustLevel>();
  await render({ levels, chat: { sessionId: "s", cwd: "/work/app", started: false, turns: 0 } });
  expect(row()).toBeNull();
  await render({ levels, chat: { sessionId: "s", cwd: "/work/app", started: true, turns: 1 } });
  expect(row()!.textContent).toBe("Claude Code can edit and run code in appTrustDon't trust");
  expect(row()!.getAttribute("title")).toBe("/work/app");
});

test("Trust saves acpmux's record and offers Undo, which forgets it and asks again", async () => {
  const levels = new Map<string, TrustLevel>();
  const chat = { sessionId: "s", cwd: "/work/app", started: true, turns: 1 };
  await render({ levels, chat });
  await press("Trust");
  expect(levels.get("/work/app")).toBe("trusted");
  expect(row()!.textContent).toBe("Trusted appUndo");
  await press("Undo");
  expect(levels.has("/work/app")).toBe(false);
  expect(row()!.textContent).toContain("can edit and run code in app");
  await press("Don't trust");
  expect(levels.get("/work/app")).toBe("untrusted");
  expect(row()!.textContent).toBe("Won't trust appUndo");
  // The answer stays until the next prompt starts.
  await render({ levels, chat: { ...chat, turns: 2 } });
  expect(row()).toBeNull();
});

test("a folder already decided, another chat, or a failed save each behave without a prompt", async () => {
  await render({
    levels: new Map([["/work/app", "trusted"]]),
    chat: { sessionId: "s", cwd: "/work/app", started: true, turns: 1 },
  });
  expect(row()).toBeNull();
  const levels = new Map<string, TrustLevel>();
  await render({ levels, chat: { sessionId: "s", cwd: "/work/app", started: true, turns: 1 } });
  expect(row()).not.toBeNull();
  await render({ levels, chat: { sessionId: "t", cwd: "/work/api", started: false, turns: 0 } });
  expect(row()).toBeNull();
  await render({ levels, chat: { sessionId: "u", cwd: "/work/web", started: true, turns: 1 }, fail: true });
  await press("Trust");
  expect(row()!.textContent).toBe("Couldn't save that. Try again.TrustDon't trust");
});

test("the mock daemon projects both agents' levels read-only, and set writes only acpmux's own record", async () => {
  const socket = new MockAcpmuxSocket();
  const answer = (
    socket as unknown as { answer(method: string, params: Record<string, unknown>): Promise<unknown> }
  ).answer.bind(socket);
  expect(await answer("acp.trust.get", { cwd: "~/code/cmux" })).toEqual({
    cwd: "~/code/cmux",
    level: "trusted",
    harnesses: { claude: "trusted", codex: "trusted" },
  });
  // atlas-web: Claude Code never decided, so the projection is unknown, but acpmux's record says trusted.
  expect(await answer("acp.trust.get", { cwd: "~/code/atlas-web" })).toEqual({
    cwd: "~/code/atlas-web",
    level: "trusted",
    harnesses: { claude: "unknown", codex: "trusted" },
  });
  expect(await answer("acp.trust.get", { cwd: "~/code/billing-service" })).toEqual({
    cwd: "~/code/billing-service",
    level: "unknown",
    harnesses: { claude: "unknown", codex: "unknown" },
  });
  expect(await answer("acp.trust.set", { cwd: "~/code/billing-service", level: "trusted" })).toEqual({
    cwd: "~/code/billing-service",
    level: "trusted",
  });
  // The decision is acpmux's; the agents' own levels read the same as before.
  expect(await answer("acp.trust.get", { cwd: "~/code/billing-service" })).toEqual({
    cwd: "~/code/billing-service",
    level: "trusted",
    harnesses: { claude: "unknown", codex: "unknown" },
  });
  // Undo: "unknown" forgets acpmux's record, and the agents' levels answer again.
  expect(await answer("acp.trust.set", { cwd: "~/code/billing-service", level: "unknown" })).toEqual({
    cwd: "~/code/billing-service",
    level: "unknown",
  });
  expect(await answer("acp.trust.get", { cwd: "~/code/billing-service" })).toMatchObject({ level: "unknown" });
  socket.close();
});

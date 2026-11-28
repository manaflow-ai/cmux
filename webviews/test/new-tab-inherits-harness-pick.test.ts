// l10n-allow-file: test fixtures, not shipped UI.
// A new chat (Cmd-N, Cmd-D, Cmd-T) starts on the harness picked last. A harness picked on its own
// default model, picked without a model (an account in the model menu), or started from a New Tab
// agent row was never remembered, so the next New Tab went back to an older harness and model
// picked before it (a subrouter Claude profile came back as plain Claude Code).
import { beforeEach, expect, test } from "bun:test";
import { lastModel, lastPick, rememberPick } from "../src/agent-session/acpmux/lastPick";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { newTabStart } from "../src/agent-session/acpmux/newtab/chipDefaults";
import { newTabScreenActions } from "../src/agent-session/acpmux/newtab/screenActions";

const store = new Map<string, string>();
(globalThis as Record<string, unknown>).localStorage = {
  getItem: (key: string) => store.get(key) ?? null,
  setItem: (key: string, value: string) => void store.set(key, value),
  removeItem: (key: string) => void store.delete(key),
};
const sent: [string, unknown][] = [];
const post = async (method: string, params: Record<string, unknown>) => {
  sent.push([method, params]);
};

// The page's native bridge (lastPick.ts sends there when no `post` is given).
(globalThis as Record<string, unknown>).window = {
  cmuxAcpmuxActions: { "newTab.remember": (params: Record<string, unknown>) => post("newTab.remember", params) },
};

beforeEach(() => {
  store.clear();
  sent.length = 0;
});

const catalog = [
  { id: "claude", name: "Claude Code", models: [{ id: "claude-opus-5-5", name: "Opus 5.5" }] },
  { id: "claude-sr-internal", name: "Claude (sr internal)", models: [{ id: "claude-opus-5-5", name: "Opus 5.5" }] },
] as unknown as AcpmuxSnapshot["catalog"];
const snapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "test",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog,
} as unknown as AcpmuxSnapshot;
const agents = catalog.map(({ id, name }) => ({ id, name }));
const FOLDER = "/Users/you/src/app";

/// The harness the next New Tab in `folder` starts on, with the app remembering `lastAgent`.
const nextNewTab = (folder = FOLDER, lastAgent?: string) =>
  newTabStart(snapshot, agents, lastAgent, folder, lastPick(folder), true).harness;

test("a harness picked on its own default model is the next New Tab's harness", () => {
  rememberPick({ harness: "claude", model: "claude-opus-5-5" }, FOLDER, post);
  rememberPick({ harness: "claude-sr-internal", model: "default" }, FOLDER, post);
  expect(nextNewTab()).toBe("claude-sr-internal");
  expect(nextNewTab("/elsewhere")).toBe("claude-sr-internal");
  // The app keeps it too, so a relaunch's New Tab starts there.
  expect(sent.at(-1)).toEqual(["newTab.remember", { agent: "claude-sr-internal", model: "default", folder: FOLDER }]);
  // Its default names no model to start on: the harness's own default stands.
  expect(lastModel("claude-sr-internal", FOLDER)).toBeUndefined();
});

test("a harness picked without a model keeps its last model, and replaces another harness's pick", () => {
  rememberPick({ harness: "claude-sr-internal", model: "claude-opus-5-5" }, FOLDER, post);
  rememberPick({ harness: "claude-sr-internal" }, FOLDER, post);
  expect(lastModel("claude-sr-internal", FOLDER)).toBe("claude-opus-5-5");
  rememberPick({ harness: "claude", model: "claude-opus-5-5" }, FOLDER, post);
  rememberPick({ harness: "claude-sr-internal" }, FOLDER, post);
  expect(nextNewTab()).toBe("claude-sr-internal");
  // The pick names no model of its own then: the harness's saved or catalog default starts it.
  expect(lastModel("claude-sr-internal", FOLDER)).toBeUndefined();
});

test("a chat started from a New Tab agent row is the next New Tab's harness", () => {
  rememberPick({ harness: "claude", model: "claude-opus-5-5" }, FOLDER, post);
  const screen = newTabScreenActions({
    callNative: async (method, params) => {
      sent.push([method, params]);
      return method === "chat.new" ? "session-1" : undefined;
    },
    chatCwd: FOLDER,
    leave: () => {},
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
  });
  void Promise.resolve(screen.onAsk("claude-sr-internal", "", undefined, undefined, undefined)).catch(() => undefined);
  expect(nextNewTab(FOLDER, "claude-sr-internal")).toBe("claude-sr-internal");
  expect(sent).toContainEqual(["newTab.remember", { agent: "claude-sr-internal", model: "default", folder: FOLDER }]);
});

test("a New Tab start remembers its pick in the folder the chat starts in, never for another machine", async () => {
  // An older pick in the project the person picks: it must not win over this start there.
  rememberPick({ harness: "claude", model: "claude-opus-5-5" }, "/b", post);
  const screen = newTabScreenActions({
    callNative: async (method, params) => {
      sent.push([method, params]);
      return method === "chat.new" ? "session-1" : undefined;
    },
    cwd: "/a",
    chatCwd: "/a",
    leave: () => {},
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
  });
  await Promise.resolve(screen.onAsk("claude-sr-internal", "", "/b", undefined, undefined)).catch(() => undefined);
  expect(nextNewTab("/b")).toBe("claude-sr-internal");
  // A chat on another machine leaves this Mac's pick alone.
  sent.length = 0;
  const saved = { peer: "studio" } as never;
  await Promise.resolve(screen.onAsk("codex", "", "/remote", undefined, undefined, undefined, saved)).catch(
    () => undefined,
  );
  expect(sent.some(([method]) => method === "newTab.remember")).toBe(false);
  expect(nextNewTab("/b")).toBe("claude-sr-internal");
});

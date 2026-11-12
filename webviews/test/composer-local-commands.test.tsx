// A harness's local command typed alone (localCommands.ts) runs at once, mid-turn too: it is never
// queued, steered or held behind the running turn, while a normal prompt mid-turn still queues (Leo,
// 2026-11-10: "typing /mcp or /status on its own should NOT queue/steer and wait behind... at least
// for these types of nonsending type messages, they should just... go there. and run. instead of
// being treated like normal messages"). cmux's own /status runs at once the same way.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { CmuxCommand } from "../src/agent-session/acpmux/cmuxCommands";
import { localCommand, localCommandNames, type LocalCommand } from "../src/agent-session/acpmux/localCommands";
import { teardownDom } from "./support/domTeardown";

const PNG = new Uint8Array(8);
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "InputEvent",
  "createImageBitmap",
  "OffscreenCanvas",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    createImageBitmap: async (source: Blob) => {
      await source.arrayBuffer();
      return { width: 640, height: 480, close() {} };
    },
    OffscreenCanvas: class {
      constructor(
        public width: number,
        public height: number,
      ) {}
      getContext() {
        return { drawImage() {}, fillRect() {}, fillStyle: "" };
      }
      async convertToBlob({ type }: { type: string }) {
        return new Blob([PNG], { type });
      }
    },
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

type Run = {
  sent: { text: string; steer?: boolean }[];
  owned: string[];
  local: string[];
  field: HTMLElement;
};

/** The composer over `snapshot` with `typed` in it; what it sends, runs as cmux's and runs locally. */
async function composer(snapshot: AcpmuxSnapshot, typed: string, shows = true): Promise<Run> {
  const run: Omit<Run, "field"> = { sent: [], owned: [], local: [] };
  let handle: ComposerHandle | null = null;
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={(text, _attachments, steer) => {
          run.sent.push({ text, steer });
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        onCmuxCommand={(command: CmuxCommand) => {
          run.owned.push(command.name);
          return true;
        }}
        onLocalCommand={(command: LocalCommand) => {
          if (!shows) return false;
          run.local.push(command.name);
          return true;
        }}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  return { ...run, field: host.querySelector<HTMLElement>("[role=combobox]")! };
}

let chats = 0;

/** A chat mid-turn, on `harness`, with Claude's own commands listed (so /mcp is one of the agent's). */
function working(harness = "claude", steering = true): AcpmuxSnapshot {
  const sessionId = `chat-${++chats}`;
  return noChat([], {
    sessionId,
    isWorking: true,
    commands: [
      { name: "mcp", description: "Manage MCP servers" },
      { name: "cost", description: "Show the session's cost" },
      { name: "compact", description: "Compact" },
    ],
    summary: { sessionId, harness, cwd: "/Users/you/src/app", turnCount: 1, steering },
    rows: [user("Add retries", 1)],
  });
}

async function enter(field: HTMLElement, metaKey = false) {
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Escape" }));
  });
  await act(async () => {
    field.dispatchEvent(
      new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Enter", keyCode: 13, metaKey }),
    );
  });
}

test("/status mid-turn runs at once: nothing is sent, so nothing queues or steers", async () => {
  const run = await composer(working(), "/status");
  await enter(run.field);
  expect({ sent: run.sent, owned: run.owned, left: run.field.textContent }).toEqual({
    sent: [],
    owned: ["status"],
    left: "",
  });
});

test("/mcp mid-turn runs at once in the GUI: nothing is sent, so nothing queues or steers", async () => {
  for (const steering of [true, false]) {
    const run = await composer(working("claude", steering), "/mcp");
    await enter(run.field);
    expect({ sent: run.sent, local: run.local, left: run.field.textContent }).toEqual({
      sent: [],
      local: ["mcp"],
      left: "",
    });
  }
});

test("a normal prompt mid-turn still steers or queues", async () => {
  const steers = await composer(working("claude", true), "Use the cache dir");
  await enter(steers.field);
  expect(steers.sent).toEqual([{ text: "Use the cache dir", steer: true }]);
  const queues = await composer(working("claude", false), "Use the cache dir");
  await enter(queues.field);
  expect(queues.sent).toEqual([{ text: "Use the cache dir", steer: false }]);
});

test("a command that sends to the model keeps the normal path: it waits for the turn", async () => {
  const run = await composer(working(), "/compact");
  await enter(run.field);
  expect({ sent: run.sent, local: run.local }).toEqual({ sent: [{ text: "/compact", steer: false }], local: [] });
});

test("a local command with arguments is the harness's, sent as typed", async () => {
  const run = await composer(working(), "/mcp reconnect github");
  await enter(run.field);
  expect(run.local).toEqual([]);
  expect(run.sent.map((sent) => sent.text)).toEqual(["/mcp reconnect github"]);
});

test("with nothing to show it in, a local command goes to the harness as typed", async () => {
  const run = await composer(working(), "/mcp", false);
  await enter(run.field);
  expect(run.sent.map((sent) => sent.text)).toEqual(["/mcp"]);
});

test("the set is per harness, and never holds a command that sends to the model", () => {
  expect(localCommand("/mcp", "claude")?.action).toEqual({ kind: "section", section: "connectors" });
  expect(localCommand("/mcp", "claude-sr")?.name).toBe("mcp");
  expect(localCommand("/diff", "codex")?.action).toEqual({ kind: "changes" });
  // Claude Code has no /diff of its own; an unknown harness has no local commands.
  expect(localCommand("/diff", "claude")).toBeUndefined();
  expect(localCommand("/mcp", "other-agent")).toBeUndefined();
  expect(localCommand("/mcp tools", "claude")).toBeUndefined();
  for (const harness of ["claude", "codex"])
    for (const sends of ["compact", "clear", "init", "review", "plan", "goal", "loop"])
      expect(localCommandNames(harness)).not.toContain(sends);
});

test("/help mid-turn opens the / menu at once: nothing is sent", async () => {
  const run = await composer(working(), "/help");
  await enter(run.field);
  expect(run.sent).toEqual([]);
  expect(run.field.textContent).toBe("/");
});

test("Codex's /diff mid-turn runs at once: the chat's changes open, nothing is sent", async () => {
  const run = await composer(working("codex", false), "/diff");
  await enter(run.field);
  expect({ sent: run.sent, local: run.local }).toEqual({ sent: [], local: ["diff"] });
});

test("Cmd-Return on /mcp mid-turn runs it at once too: nothing queues", async () => {
  const run = await composer(working("claude", true), "/mcp");
  await enter(run.field, true);
  expect({ sent: run.sent, local: run.local }).toEqual({ sent: [], local: ["mcp"] });
});

test("with nowhere to show it, a local command keeps the normal send: it steers if the agent steers", async () => {
  const run = await composer(working("codex", true), "/mcp", false);
  await enter(run.field);
  expect(run.sent).toEqual([{ text: "/mcp", steer: true }]);
});

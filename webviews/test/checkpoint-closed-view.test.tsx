// Leo, 2026-11-21: "workspace switch, opening a recent workspace, chat switch and restart reach a
// settled page (zero layout shift after first paint, streaming included) within 2x of a derived
// bound." A chat switch moved the checkpoint client to the new chat (`client.select`) in an effect,
// and the pane read the client's whole state, so that select rendered the whole pane a second time
// before the switch's first frame (bench/settled-page.bench.ts, chat_switch). While the review is
// closed the pane draws only `supported`, so it reads only that.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT", "HTMLElement", "Element", "Node"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
  });
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window });
});

/// Yields one task at a time until `ready` holds, so the test waits for the value it asserts on next.
const until = async (ready: () => boolean) => {
  for (let turn = 0; !ready(); turn++) {
    if (turn > 1000) throw new Error("the awaited state never came");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

test("a closed checkpoint review renders the pane once for a chat switch", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useCheckpoints } = await import("../src/agent-session/acpmux/checkpoints/controller");
  const { checkpointStrings } = await import("../src/agent-session/acpmux/checkpoints/strings");
  const strings = checkpointStrings();
  const request = async (method: string) => (method === "git.capabilities" ? { checkpoints: true } : {});
  const store = new Map<string, unknown>();
  const options = {
    persistence: {
      get: async (key: string) => store.get(key),
      set: async (key: string, value: unknown) => void store.set(key, value),
      delete: async (key: string) => void store.delete(key),
    },
  };
  let renders = 0;
  let supported = false;
  const Probe = ({ sessionId }: { sessionId: string }) => {
    renders += 1;
    supported = useCheckpoints({
      request,
      target: { cwd: "/home/dev/project", sessionId, hostKind: "local" },
      online: true,
      strings,
      options: options as never,
    }).supported;
    return null;
  };
  const root: Root = createRoot(document.getElementById("root")!);
  try {
    await act(async () => root.render(<Probe sessionId="chat-a" />));
    await act(() => until(() => supported));
    expect(supported).toBe(true);
    const before = renders;
    // The client moves to chat B (`client.select`) in the switch's own effect, synchronously, so the
    // act that commits the switch also flushes any render that move causes.
    await act(async () => root.render(<Probe sessionId="chat-b" />));
    // The switch's own render, and none for the client moving to chat B.
    expect(renders - before).toBe(1);
    expect(supported).toBe(true);
  } finally {
    act(() => root.unmount());
  }
});

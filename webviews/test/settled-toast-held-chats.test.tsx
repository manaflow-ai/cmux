// The chats a pane may unsettle are the ones it has shown (settledToasts.ts `useHeldChats`), read only
// when a settle toast is made. They were state, set in an effect on each chat's first visit: that
// effect ran inside the chat switch's commit and rendered the whole pane a second time before the
// switch's frame painted (bench/settled-page.bench.ts chat_switch). Kept, not drawn: a switch renders
// the pane once, and every chat it showed is still held.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useHeldChats } = await import("../src/agent-session/acpmux/settledToasts");
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const entry = (sessionId: string, peer?: string) => ({ sessionId, peer }) as unknown as AcpmuxSessionEntry;

test("a chat switch renders once, and every chat shown stays held", async () => {
  let renders = 0;
  let holds: ((entry: AcpmuxSessionEntry) => boolean) | undefined;
  function Pane({ shown }: { shown?: string }) {
    renders += 1;
    holds = useHeldChats(shown);
    return null;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    for (const [index, shown] of [undefined, "a", "b", "a", "c"].entries()) {
      await act(async () => root.render(<Pane shown={shown} />));
      expect(renders).toBe(index + 1);
    }
    expect(["a", "b", "c", "d"].map((id) => holds!(entry(id)))).toEqual([true, true, true, false]);
    // Another machine's chat of the same id is not this pane's to unsettle.
    expect(holds!(entry("a", "peer-1"))).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

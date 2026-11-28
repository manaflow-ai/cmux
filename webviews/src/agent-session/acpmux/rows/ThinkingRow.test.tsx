// l10n-allow-file: test fixtures.
import { afterAll, afterEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../../test/support/domTeardown";
import { CloudAgentStartContext } from "../conversation/CloudAgentStartLine";
import { WaitingOnContext, type WaitingOn } from "../conversation/waitingOn";
import { setLiveGlyphTrigger, useLiveGlyphTrigger } from "../conversation/thinkingGlyphModel";
import { LIVE_THINKING } from "../conversation/turns";
import type { AcpmuxRow } from "../model";

// Exercise the row's real hooks and startup line; the running turn's rendering has its own tests.
const realThinking = { ...(await import("../conversation/Thinking")) };
void mock.module("../conversation/Thinking", () => ({ Thinking: () => <span data-running-turn /> }));
afterAll(async () => {
  await mock.module("../conversation/Thinking", () => realThinking);
});
const { ThinkingRow } = await import("./ThinkingRow");

let root: Root | undefined;
let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
let saved: [string, boolean, unknown][] = [];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await teardownDom(saved, { window: dom?.window });
  dom = undefined;
  saved = [];
  setLiveGlyphTrigger("thinking");
});

function GlyphReceipt() {
  return <output data-glyph>{useLiveGlyphTrigger()}</output>;
}

test("a Cloud startup keeps its live glyph and hook order through start, run and permission transitions", async () => {
  dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", { url: "http://localhost/" });
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]]);
  Object.assign(scope, globals);
  const container = dom.window.document.querySelector("main")!;
  root = createRoot(container);
  const row: AcpmuxRow = { id: LIVE_THINKING, version: 1, at: Date.now(), kind: "thinking" };
  const render = async (queued: string | undefined, waiting?: WaitingOn) => {
    await act(async () => {
      root!.render(
        <CloudAgentStartContext.Provider value="Codex">
          <WaitingOnContext.Provider value={waiting}>
            <ThinkingRow row={{ ...row, queued }} expanded={false} onToggleActivity={() => undefined} />
            <GlyphReceipt />
          </WaitingOnContext.Provider>
        </CloudAgentStartContext.Provider>,
      );
    });
  };

  await render("prompt");
  expect(container.querySelector("[data-cloud-agent-start]")?.textContent).toContain("Starting Codex");
  expect(container.querySelector("[data-glyph]")?.textContent).toBe("turnStart");
  await render(undefined);
  expect(container.querySelector("[data-running-turn]")).not.toBeNull();
  expect(container.querySelector("[data-glyph]")?.textContent).toBe("thinking");
  await render("prompt");
  expect(container.querySelector("[data-cloud-agent-start]")).not.toBeNull();
  await render("prompt", "permission");
  expect(container.querySelector("[data-cloud-agent-start]")).toBeNull();
  expect(container.querySelector("[data-running-turn]")).not.toBeNull();
  await render("prompt");
  expect(container.querySelector("[data-cloud-agent-start]")).not.toBeNull();
});

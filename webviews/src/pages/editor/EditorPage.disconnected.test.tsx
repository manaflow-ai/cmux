// The editor page reads again on its own while the link is lost (agent-session/acpmux/autoRetry.ts) and says
// "Not connected to cmux." only once it lasts (ui/lasting.ts), in a quiet line with no button: a launch or
// a daemon restart drops the link for a few seconds (Leo, 2026-11-22: a "try again" is a vacuous decision).
import { act } from "react";
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { LASTING_MS } from "../../ui/lasting";
import { teardownDom } from "../../../test/support/domTeardown";
import { createStrings } from "../shared/i18n";
import { pageError, type PageClient } from "../shared/pageClient";
import { EditorPage, StatusStore } from "./EditorPage";
import table from "./generated/strings.json";
import { EDITOR_CONFIG_OP } from "./host";
import { EditorStore } from "./store";
import { L } from "./strings";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const settle = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

afterAll(async () => {
  jest.useRealTimers();
  await teardownDom(saved, { window: dom.window, scope: globals });
});

/** A host whose link is closed: every config read fails as the bridge does. */
function closedClient(): PageClient & { configReads: number } {
  return {
    configReads: 0,
    async call<R>(op: string): Promise<R> {
      if (op === EDITOR_CONFIG_OP) this.configReads += 1;
      throw pageError("cmux.protocol.closed", "link closed", true);
    },
    async subscribe() {
      return () => undefined;
    },
    handle() {
      return () => undefined;
    },
  };
}

test("a lost link reads again on its own, shows nothing until it lasts, then one quiet line; the link back reads again", async () => {
  jest.useFakeTimers();
  const client = closedClient();
  const store = new EditorStore(client);
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  const notice = () => rootElement.querySelector("output p")?.textContent ?? null;
  try {
    await act(async () => {
      root.render(
        <EditorPage store={store} status={new StatusStore()} strings={strings} editorRef={() => undefined} />,
      );
      await store.start();
    });
    expect(store.getState().phase).toBe("disconnected");
    // A second at a time, so each automatic ask's answer lands before the next timer.
    for (let elapsed = 0; elapsed < LASTING_MS - 1_000; elapsed += 1_000) {
      await act(async () => {
        jest.advanceTimersByTime(1_000);
        await settle();
      });
    }
    await act(async () => {
      jest.advanceTimersByTime(900);
      await settle();
    });
    expect(notice()).toBeNull();
    await act(async () => {
      jest.advanceTimersByTime(200);
      await settle();
    });
    expect(notice()).toContain(strings.t(L.disconnected));
    // No Retry button: the page asked again by itself meanwhile (1 s doubling, so several asks in 25 s).
    expect(rootElement.querySelector("button")).toBeNull();
    const asked = client.configReads;
    expect(asked).toBeGreaterThan(3);
    // The link is back: the page reads the file again at once.
    await act(async () => {
      store.linkChanged(true);
      await settle();
    });
    expect(client.configReads).toBe(asked + 1);
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
    jest.useRealTimers();
  }
});

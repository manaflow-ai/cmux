import { afterAll, afterEach, expect, test } from "bun:test";
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
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { CopyChatLink } = await import("./CopyChatLink");
const { ShortcutsContext } = await import("./shortcuts");
const { setLinkScheme } = await import("./links");

afterEach(() => setLinkScheme(undefined));

async function render(sessionId: string | undefined, shortcuts: Record<string, string>, copied: string[]) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(
      createElement(
        ShortcutsContext.Provider,
        { value: shortcuts },
        createElement(CopyChatLink, {
          sessionId,
          copy: async (text: string) => {
            copied.push(text);
          },
        }),
      ),
    ),
  );
  return { container, unmount: () => act(async () => root.unmount()) };
}

test("Copy chat link copies the session's link in the host's scheme, showing the live shortcut", async () => {
  setLinkScheme("cmux-dev-mytag");
  const copied: string[] = [];
  const { container, unmount } = await render("sess-1", { "palette.copySurfaceLink": "⌥⌘L" }, copied);
  const button = container.querySelector<HTMLButtonElement>(".acpmux-copy-link")!;
  expect(button.getAttribute("aria-label")).toBe("Copy chat link");
  expect(button.title).toBe("Copy chat link (⌥⌘L)");
  await act(async () => button.click());
  expect(copied).toEqual(["cmux-dev-mytag://session/sess-1"]);
  await unmount();
});

test("without a bound shortcut the tooltip names none", async () => {
  setLinkScheme("cmux");
  const { container, unmount } = await render("sess-1", {}, []);
  expect(container.querySelector<HTMLButtonElement>(".acpmux-copy-link")!.title).toBe("Copy chat link");
  await unmount();
});

test("a chat without a session, or a page without a scheme, has no link to copy", async () => {
  setLinkScheme("cmux");
  const fresh = await render(undefined, {}, []);
  expect(fresh.container.querySelector(".acpmux-copy-link")).toBeNull();
  await fresh.unmount();
  setLinkScheme(undefined);
  const hostless = await render("sess-1", {}, []);
  expect(hostless.container.querySelector(".acpmux-copy-link")).toBeNull();
  await hostless.unmount();
});

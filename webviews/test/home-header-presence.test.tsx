// Chief chats get the agent chat's faces (Leo, 2026-10-26: "also chief chats we need multiplayer"):
// the Home header shows who else has the conversation open, from the owner's conversation-presence.
// With nobody else there the header is as it was, and only the conversation's own members draw.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import table from "../src/pages/home-channels/generated/strings.json";
import { createStrings } from "../src/pages/shared/i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, [boolean, unknown]>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const w = dom.window;
  const globals: Record<string, unknown> = {
    window: w,
    document: w.document,
    navigator: w.navigator,
    location: w.location,
    localStorage: w.localStorage,
    HTMLElement: w.HTMLElement,
    HTMLInputElement: w.HTMLInputElement,
    HTMLTextAreaElement: w.HTMLTextAreaElement,
    Element: w.Element,
    Node: w.Node,
    Event: w.Event,
    MouseEvent: w.MouseEvent,
    KeyboardEvent: w.KeyboardEvent,
    MutationObserver: w.MutationObserver,
    getComputedStyle: w.getComputedStyle.bind(w),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
      takeRecords() {
        return [];
      }
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, [key in scope, scope[key]]);
    scope[key] = value;
  }
  w.matchMedia ??= ((query: string) => ({
    matches: false,
    media: query,
    addEventListener() {},
    removeEventListener() {},
    addListener() {},
    removeListener() {},
    onchange: null,
    dispatchEvent: () => false,
  })) as unknown as typeof w.matchMedia;
  return w.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, [had, value]] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  saved.clear();
});

async function settle() {
  for (let i = 0; i < 5; i += 1)
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
}

async function page(select: string) {
  const container = installDom();
  const { MockHomeProvider, ana, sam } = await import("../src/pages/home-channels/mockProvider");
  const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
  const { HomeChannelsPage } = await import("../src/pages/home-channels/HomeChannelsPage");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const provider = new MockHomeProvider(undefined, false, "none", false, false, true);
  // The mock has no avatar pictures (the gallery draws initials); a page reading one gets none.
  const call = provider.call.bind(provider);
  provider.call = (async (op: string, params?: Record<string, unknown>) =>
    op === "cmux.home.avatar" ? { avatar: null } : call(op, params)) as typeof provider.call;
  const store = new HomeChannelsStore(provider, undefined, null);
  store.routed = false;
  await store.select(select);
  const strings = createStrings(table, ["en"]);
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container}>
        <HomeChannelsPage store={store} strings={strings} pane="conversation" />
      </UiProvider>,
    );
  });
  await settle();
  const header = () => container.querySelector(".lg-header");
  const faces = () => [...(header()?.querySelectorAll(".cv-presence .cv-face") ?? [])];
  return { provider, header, faces, ana, sam };
}

test("with nobody else here the header has no faces; a teammate who opens it shows", async () => {
  const { provider, header, faces, sam } = await page("c-launch");
  expect(header()).not.toBeNull();
  expect(header()!.querySelector(".cv-presence")).toBeNull();
  await act(async () => provider.viewing("c-launch", [sam.id]));
  await settle();
  expect(faces().length).toBe(1);
  expect(header()!.querySelector(".cv-presence__label")?.textContent).toContain("Sam");
});

test("someone who is not in the conversation never shows in its header", async () => {
  // #design's members are agents; Ana is in #launch only.
  const { provider, header, ana } = await page("c-design");
  await act(async () => provider.viewing("c-design", [ana.id]));
  await act(async () => provider.typing("c-design", ana.id, true));
  await settle();
  expect(header()!.querySelector(".cv-presence")).toBeNull();
});

// Home installs only the agent pane keys it draws (scripts/pages/gen-strings.mjs
// `home-channels-pane`, paneStrings.ts); the faces' strings must be among them, or the header reads
// `multiplayer.viewing` instead of the names.
test("Home's own pane table has every string the shared chat faces draw", async () => {
  const { readFileSync } = await import("node:fs");
  const faces = readFileSync(new URL("../src/agent-session/acpmux/multiplayer/Faces.tsx", import.meta.url), "utf8");
  const used = [...new Set([...faces.matchAll(/t\("(multiplayer\.[\w.]+)"/g)].map((m) => m[1]!))];
  expect(used.length).toBeGreaterThan(0);
  const table = JSON.parse(
    readFileSync(new URL("../src/pages/home-channels/generated/pane-strings.json", import.meta.url), "utf8"),
  ) as Record<string, unknown>;
  const text = JSON.stringify(table);
  for (const key of used) expect(text).toContain(`"${key}"`);
});

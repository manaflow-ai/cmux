// The default New Tab keeps its quick action pills and its template dots (Leo 2026-10-22: "lucas
// noticed i accidentally fucking removed the dots... idk how we removed EVERYTHING... incl the cards
// situation"; about the pills and the dots: "let's turn it back on"). #22674 made both widgets that
// were off by default, so a page with no `tabs.newTabWidgets` keys showed only the greeting and the
// composer. With no keys set the page now shows, under the composer, New terminal, New browser tab
// and New chat as the quiet outlined pills (not the stage's card: the page stays the calm one, the
// composer about the window's middle), and under the page the two composer look dots then the
// template dots (Minimal, Cards, ...). Each still turns off in Settings.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import { PAGE_STYLES, shownTemplate } from "../src/agent-session/acpmux/newtab/templates";
import { shownPageWidgets, type PageWidgets } from "../src/agent-session/acpmux/newtab/pageWidgets";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "http://localhost/" })
    .window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
// The page a host with no `tabs.newTabTemplate` and no `tabs.newTabWidgets` keys opens.
const template = shownTemplate({ layout: "b" });
const defaults = (): PageWidgets => shownPageWidgets(template);

async function renderScreen(widgets: PageWidgets): Promise<Root> {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <NewTabScreen
        template="minimal"
        pageWidgets={widgets}
        snapshot={noChat(manySessions(12))}
        lastAgent="claude"
        cwd="/Users/you/src/atlas"
        projects={[{ cwd: "/Users/you/src/atlas", label: "atlas" }]}
        loadChatsPage={async () => ({ ready: true, chats: [] })}
        onOpenChat={noop}
        onCreate={noop}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  return root;
}

async function renderDots(styleDots: boolean): Promise<Root> {
  const { createRoot } = await import("react-dom/client");
  const { PageDots } = await import("../src/agent-session/acpmux/newtab/PageDots");
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <PageDots
        template={template}
        styleDots={styleDots}
        callNative={async () => undefined}
        show={noop}
        onCancel={noop}
      />,
    ),
  );
  return root;
}

test("a default New Tab shows New terminal, New browser tab and New chat as pills under the composer", async () => {
  expect(template).toBe("minimal");
  const root = await renderScreen(defaults());
  try {
    const screen = host.querySelector(".nt-screen")!;
    // The calm page: no stage, no cards; the composer about the window's middle.
    expect(screen.hasAttribute("data-minimal")).toBe(true);
    expect(host.querySelector(".nt-stage, .nt-suggest, .nt-env, .nt-cards")).toBeNull();
    const pills = [...host.querySelectorAll<HTMLButtonElement>(".nt-create.ui-ghost-row [data-create]")];
    expect(pills.map((pill) => pill.dataset.create)).toEqual(["terminal", "browser", "chat"]);
    expect(pills.map((pill) => pill.textContent)).toEqual(["New terminal", "New browser tab", "New chat"]);
    // Under the composer.
    const composer = host.querySelector(".nt-composer")!;
    expect(composer.compareDocumentPosition(pills[0]!) & window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a default New Tab shows the template dots after the two look dots", async () => {
  expect(defaults().has("styleDots")).toBe(true);
  const root = await renderDots(defaults().has("styleDots"));
  try {
    const looks = [...host.querySelectorAll<HTMLInputElement>(".nt-look-dots input[type=radio]")];
    expect(looks.map((radio) => radio.value)).toEqual(["claude", "codex"]);
    const styles = [...host.querySelectorAll<HTMLInputElement>(".nt-style:not(.nt-look-dots) input[type=radio]")];
    expect(styles.map((radio) => radio.value)).toEqual([...PAGE_STYLES]);
    expect(styles.find((radio) => radio.checked)?.value).toBe("minimal");
  } finally {
    await act(async () => root.unmount());
  }
});

test("each still turns off: the actions off leave the greeting and the composer, the dots off the looks", async () => {
  let root = await renderScreen(shownPageWidgets(template, ["greeting"]));
  try {
    expect(host.querySelector(".nt-screen")?.hasAttribute("data-minimal")).toBe(true);
    expect(host.querySelector(".nt-create")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
  root = await renderDots(false);
  try {
    expect(host.querySelectorAll(".nt-style input[type=radio]")).toHaveLength(2);
  } finally {
    await act(async () => root.unmount());
  }
});

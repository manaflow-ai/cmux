// The Cards New Tab template (u2851, a scrawl of Aside's New Tab page: "make our new tab page look
// like this. Have an option for this version of it"). One rounded field holding the Search | Ask
// switch and its "Tab to switch" hint; under the field, one row with the project, the agent's chips
// and the mic (no Send disc: Return sends); the row steps aside while Search is on; then "Chats"
// with "All Chats >" and three tall chat cards. It is the page an unset `tabs.newTabTemplate`
// shows; Default and the others stay one pick away.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import {
  NEW_TAB_TEMPLATES,
  PAGE_STYLES,
  parseNewTabTemplate,
  screenSections,
  screenTemplate,
  shownTemplate,
} from "../src/agent-session/acpmux/newtab/templates";

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
  "ResizeObserver",
  "MutationObserver",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
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
    // The split's quiet row fits its labels to the width (composerRowFit.ts useRowFit).
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    MutationObserver: window.MutationObserver,
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

test("Cards is a template and a style, and the page an unset template shows", () => {
  expect(NEW_TAB_TEMPLATES).toContain("cards");
  expect(PAGE_STYLES[0]).toBe("cards");
  expect(parseNewTabTemplate("cards")).toBe("cards");
  expect(screenTemplate("cards")).toBe("cards");
  expect(screenSections("cards")).toEqual({ chats: "cards", allChats: false, recent: 3, prompt: false, closed: false });
  // Unset: Cards. Debug Settings design "a" still shows Classic; a saved pick always wins.
  expect(shownTemplate({ layout: "b" })).toBe("cards");
  expect(shownTemplate({ layout: "a" })).toBe("classic");
  expect(shownTemplate({ layout: "b", template: "default" })).toBe("default");
});

test("the Cards page: one field with Search | Ask, a chip row under it, three chat cards", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  let showAll = 0;
  try {
    await act(async () =>
      root.render(
        <NewTabScreen
          template="cards"
          snapshot={noChat(manySessions(8))}
          lastAgent="claude"
          accessory={<button type="button" className="acpmux-mic" aria-label="Dictate" />}
          onAsk={noop}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
          onOpenSession={noop}
          onShowAll={() => (showAll += 1)}
        />,
      ),
    );
    const screen = host.querySelector<HTMLElement>(".nt-screen")!;
    const box = host.querySelector<HTMLElement>(".nt-box")!;
    const toolbar = host.querySelector<HTMLElement>(".nt-toolbar");
    expect(screen.dataset.template).toBe("cards");
    // The field and its switch are the pill; the project, chips and mic are a row under it.
    expect(box.querySelector(".nt-field")).not.toBeNull();
    expect(box.querySelector(".nt-mode")).not.toBeNull();
    expect(toolbar).not.toBeNull();
    expect(box.contains(toolbar)).toBe(false);
    expect(toolbar!.querySelector(".nt-location")).not.toBeNull();
    expect(toolbar!.querySelector(".nt-pickers .acpmux-mic")).not.toBeNull();
    expect(box.querySelector(".nt-location")).toBeNull();
    // Return sends; the page draws no Send disc and no create row.
    expect(host.querySelector(".nt-send")).toBeNull();
    expect(host.querySelector(".nt-create")).toBeNull();
    // Three tall cards in a grid, "All Chats >" beside the Chats header.
    expect(host.querySelectorAll(".nt-cards[data-variant=cards] .nt-card").length).toBe(3);
    await act(async () => host.querySelector<HTMLButtonElement>(".nt-chats-all")!.click());
    expect(showAll).toBe(1);

    // Search hides the chip row (the suggestions take its place), Ask brings it back.
    expect(screen.dataset.mode).toBe("ask");
    await act(async () => host.querySelector<HTMLButtonElement>('.nt-mode button[data-mode="search"]')!.click());
    expect(screen.dataset.mode).toBe("search");
    await act(async () => host.querySelector<HTMLButtonElement>('.nt-mode button[data-mode="ask"]')!.click());
    expect(screen.dataset.mode).toBe("ask");
  } finally {
    await act(async () => root.unmount());
  }
});

test("the other templates keep their composer card and Send disc", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <NewTabScreen
          template="default"
          snapshot={noChat(manySessions(8))}
          lastAgent="claude"
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
    expect(host.querySelector(".nt-toolbar")).toBeNull();
    expect(host.querySelector(".nt-box .nt-send")).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

// Claude Code's split on Cards (Leo 2026-10-19: "put the claude code style composer on the first
// dot in the new tab page and put the existing composer on the second one"). With the agent's chips
// and the plain footer (on by default), Cards draws the chat composer's box: the prompt, the mic and
// Send inside it, the mode, model and effort in the quiet row under it. Nothing hides the mic, in
// Ask or in Search (the mic never leaves the New Tab composer).
test("Cards with the agent's chips draws the split, and the mic stays in the box in Search", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  const Chips = () => (
    <span className="acpmux-chips">
      <button type="button" className="acpmux-model" aria-label="Model" />
    </span>
  );
  try {
    await act(async () =>
      root.render(
        <NewTabScreen
          template="cards"
          snapshot={noChat(manySessions(8))}
          lastAgent="claude"
          chips={Chips}
          accessory={<button type="button" className="acpmux-mic" aria-label="Dictate" />}
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
    const screen = host.querySelector<HTMLElement>(".nt-screen")!;
    const box = host.querySelector<HTMLElement>(".nt-box")!;
    // The split, not the pill: no toolbar under a pill; the mic and Send in the box; the chips in
    // the quiet row under it; the project strip heads the card.
    expect(screen.dataset.pill).toBeUndefined();
    expect(host.querySelector(".nt-toolbar")).toBeNull();
    expect(box.querySelector(".nt-pickers .acpmux-mic")).not.toBeNull();
    expect(box.querySelector(".nt-send")).not.toBeNull();
    expect(box.querySelector(".acpmux-model")).toBeNull();
    expect(host.querySelector(".nt-foot .acpmux-composer-foot .acpmux-model")).not.toBeNull();
    const composer = host.querySelector<HTMLElement>(".nt-composer")!;
    expect(composer.firstElementChild?.classList.contains("nt-location")).toBe(true);
    // Cards draws no create row with the split either (u2851): the app always passes the chips.
    expect(host.querySelector(".nt-create")).toBeNull();
    // Search keeps the mic where it is: nothing that Search hides holds it.
    await act(async () => host.querySelector<HTMLButtonElement>('.nt-mode button[data-mode="search"]')!.click());
    expect(screen.dataset.mode).toBe("search");
    const mic = box.querySelector<HTMLElement>(".acpmux-mic");
    expect(mic).not.toBeNull();
    expect(mic!.closest(".nt-toolbar")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

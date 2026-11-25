// A widget that throws while it draws never takes the New Tab page down (cmux.widget/1): the
// composer stays, the other tiles keep their scenes, and only the throwing tile says it is
// unavailable. Without the grid's and the tiles' error boundaries (NewTabWidgets.tsx) one tile's
// throw unmounted the whole NewTabScreen, composer included.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { AppWidgetsClient, type WidgetTilePlacement } from "../src/apps/scene/widgetsClient";
import { MockWidgetsHost } from "../src/apps/scene/widgetsMock";
import { teardownDom } from "./support/domTeardown";

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
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    MutationObserver: window.MutationObserver,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const noop = () => {};
const placed: WidgetTilePlacement[] = [
  { instance: "w1", app: "cmux/clock", size: "small" },
  { instance: "w2", app: "cmux/weather", size: "medium" },
  { instance: "w3", app: "cmux/todo", size: "large" },
];

async function settled(rounds = 12) {
  for (let i = 0; i < rounds; i++) await new Promise<void>((resolve) => setTimeout(resolve, 0));
}

test("a tile that throws while it draws leaves the composer and the other tiles on the page", async () => {
  // The weather tile throws on every draw (a bad scene, a renderer bug): any throw in its subtree.
  const realTile = AppWidgetsClient.prototype.tile;
  AppWidgetsClient.prototype.tile = function (this: AppWidgetsClient, instance: string) {
    const tile = realTile.call(this, instance);
    if (tile && instance === "w2") {
      (tile as unknown as { getHealth: () => never }).getHealth = () => {
        throw new Error("weather widget render threw");
      };
    }
    return tile;
  };
  const quiet = console.error;
  console.error = () => {};
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { NewTabWidgetsHost } = await import("../src/agent-session/acpmux/newtab/NewTabWidgets");
  const widgets = new MockWidgetsHost(placed);
  const root: Root = createRoot(host);
  try {
    await act(async () => {
      root.render(
        <NewTabWidgetsHost value={widgets}>
          <NewTabScreen
            template="minimal"
            snapshot={noChat([])}
            lastAgent="claude"
            onAsk={noop}
            onOpen={noop}
            onSearch={noop}
            onShell={noop}
            onJump={noop}
            onOpenSession={noop}
            onShowAll={noop}
          />
        </NewTabWidgetsHost>,
      );
      await settled();
    });
    expect(host.querySelector(".nt-composer")).not.toBeNull();
    const tiles = [...host.querySelectorAll<HTMLElement>(".nt-widget-tile")];
    expect(tiles.map((tile) => tile.dataset.app)).toEqual(["cmux/clock", "cmux/weather", "cmux/todo"]);
    const [clock, weather, todo] = tiles;
    expect(weather!.querySelector('.nt-widget-card[data-status="failed"] .nt-widget-notice')).not.toBeNull();
    for (const tile of [clock!, todo!]) {
      expect(tile.querySelector('.nt-widget-card[data-status="failed"]')).toBeNull();
      expect(tile.querySelector(".cmux-app-scene-root")).not.toBeNull();
    }
  } finally {
    await act(async () => root.unmount());
    AppWidgetsClient.prototype.tile = realTile;
    console.error = quiet;
  }
});

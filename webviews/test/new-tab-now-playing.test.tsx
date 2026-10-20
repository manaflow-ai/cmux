// The New Tab page's Now Playing player: what plays (the host's `nowPlaying` push: cmux's player, a
// browser tab, Spotify, Music) shows large under the create actions with its artwork, title and
// artist; Play or Pause follows the track; the controls ask the host (`nowPlaying.command`); and
// nothing shows once the host clears it (nothing plays, or sidebar.nowPlaying.enabled is off).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

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
  "customElements",
  "MutationObserver",
] as const;
const added: string[] = [];
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
    customElements: window.customElements,
    MutationObserver: window.MutationObserver,
  });
  // Pierre's registered elements (App's diff view) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
const ART =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
const track = (playing: boolean) => ({
  title: "Weightless",
  artist: "Marconi Union",
  artwork: ART,
  playing,
  position: 60,
  duration: 480,
  rate: 1,
  positionDate: Date.now(),
  canPrevious: true,
  canNext: false,
  labels: { play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track" },
});

test("the player shows what plays, and its controls reach the host", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => void calls.push({ method, params }),
    cwd: "/Users/you/src/app",
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  // Pushed before the screen mounts: the page keeps it.
  applyHostEvent({ kind: "nowPlaying", value: track(true) });
  const root: Root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <QueryClientProvider client={new QueryClient()}>
          <NewTabScreen snapshot={noChat()} lastAgent="claude" cwd="/Users/you/src/app" {...actions} />
        </QueryClientProvider>,
      ),
    );
    const player = host.querySelector<HTMLElement>(".nt-player");
    expect(player, "no player while a track plays").toBeTruthy();
    expect(player!.getAttribute("aria-label")).toBe("Now Playing");
    expect(player!.dataset.playing).toBe("true");
    expect(host.querySelector(".nt-player-title")?.textContent).toBe("Weightless");
    expect(host.querySelector(".nt-player-artist")?.textContent).toBe("Marconi Union");
    expect(host.querySelector<HTMLImageElement>(".nt-player-art img")?.getAttribute("src")).toBe(ART);
    const played = host.querySelector<HTMLElement>(".nt-player-played");
    expect(parseFloat(played?.style.width ?? "0")).toBeGreaterThanOrEqual(12.5);
    expect(parseFloat(played?.style.width ?? "0")).toBeLessThan(14);
    // Under the create actions, before the lists.
    const create = host.querySelector(".nt-create")!;
    expect(create.compareDocumentPosition(player!) & window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

    const button = (command: string) =>
      host.querySelector<HTMLButtonElement>(`.nt-player [data-command="${command}"]`)!;
    expect(button("playPause").getAttribute("aria-label")).toBe("Pause");
    expect(button("next").disabled, "Next is enabled when the source has no next track").toBe(true);
    await act(async () => button("playPause").click());
    await act(async () => button("previous").click());
    await act(async () => button("next").click());
    expect(calls.filter((call) => call.method === "nowPlaying.command")).toEqual([
      { method: "nowPlaying.command", params: { command: "playPause" } },
      { method: "nowPlaying.command", params: { command: "previous" } },
    ]);

    await act(async () => applyHostEvent({ kind: "nowPlaying", value: track(false) }));
    expect(host.querySelector<HTMLElement>(".nt-player")?.dataset.playing).toBe("false");
    expect(button("playPause").getAttribute("aria-label")).toBe("Play");

    await act(async () => applyHostEvent({ kind: "nowPlaying", value: null }));
    expect(host.querySelector(".nt-player"), "the player stays after the host cleared it").toBeNull();
  } finally {
    act(() => root.unmount());
    const { setNowPlaying } = await import("../src/agent-session/acpmux/newtab/nowPlaying");
    setNowPlaying(null);
  }
});

test("a malformed push shows no player and keeps only image data URLs", async () => {
  const { setNowPlaying, nowPlaying } = await import("../src/agent-session/acpmux/newtab/nowPlaying");
  setNowPlaying({ artist: "no title" });
  expect(nowPlaying()).toBeNull();
  setNowPlaying({ ...track(true), artwork: "https://example.com/art.png", duration: -1, rate: "fast" });
  const shown = nowPlaying();
  expect(shown?.artwork).toBeUndefined();
  expect(shown?.duration).toBeUndefined();
  expect(shown?.rate).toBe(1);
  setNowPlaying(null);
});

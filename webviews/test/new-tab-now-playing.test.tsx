// The New Tab page's Now Playing player: what plays (the host's `nowPlaying` push: cmux's player, a
// browser tab, Spotify, Music) shows large under the create actions with its artwork, title and
// artist; Play or Pause follows the track; the controls ask the host (`nowPlaying.command`); and
// nothing shows once the host clears it (nothing plays, or tabs.newTabNowPlaying is off). Its right-click menu (Shift-F10 too) runs the controls, opens the
// app that plays, hides the player with an Undo, and opens its setting.
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
  "MouseEvent",
  "KeyboardEvent",
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
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
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
          <NewTabScreen template="default" snapshot={noChat()} lastAgent="claude" cwd="/Users/you/src/app" {...actions} />
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
    // Progress is a compositor-only scaleX of a full-width bar, not a width.
    const scale = Number(/scaleX\(([^)]+)\)/.exec(played?.style.transform ?? "")?.[1] ?? "0");
    expect(scale).toBeGreaterThanOrEqual(0.125);
    expect(scale).toBeLessThan(0.14);
    expect(played?.style.width ?? "").toBe("");
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

async function mount(calls: { method: string; params?: Record<string, unknown> }[]) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const actions = newTabScreenActions({
    callNative: async (method, params) => void calls.push({ method, params }),
    cwd: "/Users/you/src/app",
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      <QueryClientProvider client={new QueryClient()}>
        <NewTabScreen template="default" snapshot={noChat()} lastAgent="claude" cwd="/Users/you/src/app" {...actions} />
      </QueryClientProvider>,
    ),
  );
  return root;
}

const menu = () => window.document.querySelector<HTMLElement>('.ui-context-menu[role="menu"]');
const menuItems = () =>
  [...window.document.querySelectorAll<HTMLButtonElement>('.ui-context-menu [role="menuitem"]')].map((item) => ({
    label: item.textContent,
    disabled: item.disabled,
  }));
const pick = async (label: string) => {
  const item = [...window.document.querySelectorAll<HTMLButtonElement>('.ui-context-menu [role="menuitem"]')].find(
    (candidate) => candidate.textContent === label,
  );
  expect(item, `no "${label}" in the menu`).toBeTruthy();
  await act(async () => item!.click());
};
const rightClick = async (target: Element) =>
  act(async () => {
    target.dispatchEvent(
      new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 }),
    );
  });
const commands = (calls: { method: string; params?: Record<string, unknown> }[]) =>
  calls.filter((call) => call.method === "nowPlaying.command").map((call) => call.params?.command);

test("the player's right-click menu runs the controls, opens the app that plays and its setting", async () => {
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { setNowPlaying } = await import("../src/agent-session/acpmux/newtab/nowPlaying");
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  applyHostEvent({ kind: "nowPlaying", value: { ...track(true), source: "Spotify" } });
  const root = await mount(calls);
  try {
    await rightClick(host.querySelector(".nt-player-title")!);
    expect(menu(), "a right-click on the card opens no menu").toBeTruthy();
    expect(menuItems()).toEqual([
      { label: "Pause", disabled: false },
      { label: "Next Track", disabled: true },
      { label: "Previous Track", disabled: false },
      { label: "Open in Spotify", disabled: false },
      { label: "Hide Now Playing", disabled: false },
      { label: "Now Playing Settings…", disabled: false },
    ]);
    // One separator, before Hide: the page's own items after the transport.
    const separators = [...window.document.querySelectorAll(".ui-context-menu .ui-separator")];
    expect(separators.length).toBe(1);
    expect(separators[0]!.parentElement?.textContent).toBe("Hide Now Playing");
    await pick("Pause");
    expect(menu(), "the menu stays open after an item").toBeNull();
    await rightClick(host.querySelector(".nt-player-art")!);
    await pick("Previous Track");
    await rightClick(host.querySelector(".nt-player")!);
    await pick("Open in Spotify");
    await rightClick(host.querySelector(".nt-player")!);
    await pick("Now Playing Settings…");
    expect(commands(calls)).toEqual(["playPause", "previous", "open", "settings"]);

    // Keyboard: Shift-F10 on a focused control opens the same menu; Escape closes it.
    const play = host.querySelector<HTMLButtonElement>('.nt-player [data-command="playPause"]')!;
    play.focus();
    await act(async () => {
      play.dispatchEvent(
        new window.KeyboardEvent("keydown", { key: "F10", shiftKey: true, bubbles: true, cancelable: true }),
      );
    });
    expect(menu(), "Shift-F10 opens no menu").toBeTruthy();
    await act(async () => {
      menu()!.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    });
    expect(menu()).toBeNull();

    // cmux's own player and tabs name no app: no Open in item; paused, the first item is Play.
    await act(async () => applyHostEvent({ kind: "nowPlaying", value: { ...track(false), canNext: true } }));
    await rightClick(host.querySelector(".nt-player")!);
    expect(menuItems().map((item) => item.label)).toEqual([
      "Play",
      "Next Track",
      "Previous Track",
      "Hide Now Playing",
      "Now Playing Settings…",
    ]);
    expect(menuItems().every((item) => !item.disabled)).toBe(true);
    await pick("Next Track");
    expect(commands(calls).at(-1)).toBe("next");
  } finally {
    act(() => root.unmount());
    setNowPlaying(null);
  }
});

test("Hide Now Playing turns the setting off and leaves an Undo in its place", async () => {
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { setNowPlaying } = await import("../src/agent-session/acpmux/newtab/nowPlaying");
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  applyHostEvent({ kind: "nowPlaying", value: track(true) });
  const root = await mount(calls);
  try {
    await rightClick(host.querySelector(".nt-player")!);
    await pick("Hide Now Playing");
    expect(commands(calls)).toEqual(["hide"]);
    expect(host.querySelector(".nt-player"), "the card stays after Hide").toBeNull();
    const note = host.querySelector<HTMLElement>(".nt-player-note");
    // An <output>: the status role is its own (a live region).
    expect(note?.tagName).toBe("OUTPUT");
    expect(note?.textContent).toContain("You can show it again in Settings.");
    // The host clears the track once the setting is off; the note stays until Undo.
    await act(async () => applyHostEvent({ kind: "nowPlaying", value: null }));
    expect(host.querySelector(".nt-player-note")).toBeTruthy();
    await act(async () => host.querySelector<HTMLButtonElement>(".nt-player-undo")!.click());
    expect(commands(calls)).toEqual(["hide", "show"]);
    expect(host.querySelector(".nt-player-note")).toBeNull();
    await act(async () => applyHostEvent({ kind: "nowPlaying", value: track(true) }));
    expect(host.querySelector(".nt-player"), "the card is back after Undo").toBeTruthy();
  } finally {
    act(() => root.unmount());
    setNowPlaying(null);
  }
});

test("with the setting off the page draws no player and keeps no space for it", async () => {
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  // The host pushes null at load and handshake while tabs.newTabNowPlaying is off.
  applyHostEvent({ kind: "nowPlaying", value: null });
  // Generated ids (useId) differ from one mount to the next; nothing else may.
  const markup = () => host.innerHTML.replace(/ (id|aria-controls|aria-labelledby|aria-describedby|for)="[^"]*"/g, "");
  const off = await mount(calls);
  const offMarkup = markup();
  expect(host.querySelector(".nt-player, .nt-player-host, .nt-player-note")).toBeNull();
  act(() => off.unmount());
  // Byte for byte the page with nothing playing at all: no placeholder, no reserved box.
  const { setNowPlaying } = await import("../src/agent-session/acpmux/newtab/nowPlaying");
  setNowPlaying(undefined);
  const never = await mount(calls);
  try {
    expect(markup()).toBe(offMarkup);
  } finally {
    act(() => never.unmount());
  }
});

test("a malformed push shows no player and keeps only image data URLs", async () => {
  const { setNowPlaying, nowPlaying } = await import("../src/agent-session/acpmux/newtab/nowPlaying");
  setNowPlaying({ artist: "no title" });
  expect(nowPlaying()).toBeNull();
  setNowPlaying({ ...track(true), artwork: "https://example.com/art.png", duration: -1, rate: "fast", source: 7 });
  const shown = nowPlaying();
  expect(shown?.artwork).toBeUndefined();
  expect(shown?.source).toBeUndefined();
  setNowPlaying({ ...track(true), source: "  Music  " });
  expect(nowPlaying()?.source).toBe("Music");
  expect(shown?.duration).toBeUndefined();
  expect(shown?.rate).toBe(1);
  setNowPlaying(null);
});

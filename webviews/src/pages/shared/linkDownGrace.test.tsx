// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the f*** up and load
// faster/percievably load faster / whatever it takes / desktop gui, ios, remote, cloud, etc".
//
// A daemon restart or an update's handoff drops every page's link for a few seconds. The pages here said
// so at once, and two of them swapped their list for the message: Settings dropped in "read only",
// Keybindings and Passwords blanked their lists, Tasks put up "Lost the connection", CodeRouter "not
// available". Each now keeps what it shows and says the link is down only once that lasts (ui/lasting.ts,
// the grace every other page already waits out).
import { act, type ReactNode } from "react";
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { LASTING_MS } from "../../ui/lasting";
import { teardownDom } from "../../../test/support/domTeardown";
import { installVirtualSizes } from "../../../test/support/virtualSizes";
import { createStrings } from "./i18n";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  HTMLInputElement: dom.window.HTMLInputElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MouseEvent: dom.window.MouseEvent,
  KeyboardEvent: dom.window.KeyboardEvent,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { createRoot } = await import("react-dom/client");

afterAll(async () => {
  jest.useRealTimers();
  await teardownDom(saved, { window: dom.window, scope: globals });
});

const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

/// Renders `node`, runs `start` (the store's first read, on a live link), then hands the page to `body`.
async function mounted(node: ReactNode, body: (element: HTMLElement) => Promise<void>): Promise<void> {
  jest.useFakeTimers();
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  try {
    await act(async () => {
      root.render(node);
      await settle();
    });
    await body(element);
  } finally {
    await act(async () => root.unmount());
    element.remove();
    jest.useRealTimers();
  }
}

async function advance(ms: number): Promise<void> {
  await act(async () => {
    jest.advanceTimersByTime(ms);
    await settle();
  });
}

test("Settings: a lost link drops in no read-only banner until it lasts", async () => {
  const { ReadOnlyNotice } = await import("../settings/components/ReadOnlyBanner");
  await mounted(<ReadOnlyNotice connected={false} loaded readable />, async (element) => {
    const banner = () => element.querySelector("[data-read-only=disconnected]");
    expect(banner()).toBeNull();
    await advance(LASTING_MS - 100);
    expect(banner()).toBeNull();
    await advance(200);
    expect(banner()).not.toBeNull();
  });
  // A first read that failed is no link blip: said at once, as before.
  await mounted(<ReadOnlyNotice connected loaded readable={false} />, async (element) => {
    expect(element.querySelector("[data-read-only=loadFailed]")).not.toBeNull();
  });
});

test("Keybindings: a lost link keeps the list and says so only once it lasts", async () => {
  const { KeybindingsPage } = await import("../keybindings/KeybindingsPage");
  const { KeybindingsStore } = await import("../keybindings/store");
  const { MockKeybindingsProvider } = await import("../keybindings/mockProvider");
  const table = (await import("../keybindings/generated/strings.json")).default;
  const strings = createStrings(table);
  const provider = new MockKeybindingsProvider();
  const store = new KeybindingsStore(provider);
  await mounted(<KeybindingsPage store={store} strings={strings} />, async (element) => {
    const message = strings.t("keybindings.page.disconnected");
    expect(element.querySelector(".keys-scroll")).not.toBeNull();
    await act(async () => {
      provider.page.setConnected(false);
      await settle();
    });
    expect(store.getSnapshot().connection).toBe("disconnected");
    await advance(LASTING_MS - 100);
    expect(element.querySelector(".keys-scroll")).not.toBeNull();
    expect(element.textContent).not.toContain(message);
    await advance(200);
    expect(element.textContent).toContain(message);
  });
});

test("Passwords: a lost link keeps the list and says so only once it lasts", async () => {
  // The lists are windowed: give the scroller a viewport and its rows a height, as a browser would.
  installVirtualSizes(dom.window, (element) => (element.classList.contains("pw-scroll") ? 600 : 30));
  const { PasswordsPage } = await import("../passwords/PasswordsPage");
  const { PasswordsStore } = await import("../passwords/store");
  const { MockPasswordsProvider } = await import("../passwords/mockProvider");
  const table = (await import("../passwords/generated/strings.json")).default;
  const strings = createStrings(table);
  const provider = new MockPasswordsProvider();
  const store = new PasswordsStore(provider);
  await mounted(<PasswordsPage store={store} strings={strings} />, async (element) => {
    expect(element.querySelector(".pw-row")).not.toBeNull();
    await act(async () => {
      provider.streams.setConnected(false);
      await settle();
    });
    expect(store.getSnapshot().connection).toBe("disconnected");
    await advance(LASTING_MS - 100);
    expect(element.querySelector(".pw-row")).not.toBeNull();
    expect(element.querySelector(".pw-disconnected")).toBeNull();
    await advance(200);
    expect(element.querySelector(".pw-disconnected")).not.toBeNull();
  });
});

test("CodeRouter: a page with nothing read yet stays blank, not 'not available', until the loss lasts", async () => {
  const { CodeRouterPage } = await import("../coderouter/CodeRouterPage");
  const { CodeRouterStore } = await import("../coderouter/store");
  const table = (await import("../coderouter/generated/strings.json")).default;
  const strings = createStrings(table);
  // No host: the store is disconnected from its first frame, with no status read.
  const store = new CodeRouterStore(null);
  await mounted(<CodeRouterPage store={store} strings={strings} />, async (element) => {
    const message = strings.t("disconnected");
    expect(element.textContent).not.toContain(message);
    await advance(LASTING_MS - 100);
    expect(element.textContent).not.toContain(message);
    await advance(200);
    expect(element.textContent).toContain(message);
  });
});

test("Tasks: an owner that drops is said lost only once that lasts", async () => {
  const { TasksPage } = await import("../tasks/TasksPage");
  const { TasksStore } = await import("../tasks/store");
  const { MockTasksProvider } = await import("../tasks/mockProvider");
  const table = (await import("../tasks/generated/strings.json")).default;
  const strings = createStrings(table);
  const provider = new MockTasksProvider();
  let key = 0;
  const store = new TasksStore(provider, { newKey: () => `k${++key}`, schedule: () => () => {}, visible: () => true });
  await mounted(<TasksPage store={store} strings={strings} layout="list" />, async (element) => {
    await act(async () => {
      await store.start();
      await settle();
    });
    expect(store.getSnapshot().everConnected).toBe(true);
    await act(async () => {
      provider.setHostConnected(false);
      await settle();
    });
    expect(store.getSnapshot().connection).toBe("unreachable");
    await advance(LASTING_MS - 100);
    expect(element.querySelector(".tasks-banner")).toBeNull();
    await advance(200);
    expect(element.querySelector(".tasks-banner")).not.toBeNull();
  });
});

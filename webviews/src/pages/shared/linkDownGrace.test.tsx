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
import { CONNECTION_QUIET_MS } from "../../ui/lasting";
import { teardownDom } from "../../../test/support/domTeardown";
import { installVirtualSizes } from "../../../test/support/virtualSizes";
import { createStrings } from "./i18n";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
// jsdom draws no layout, so it has no scrollIntoView; the Bookmarks tree reveals its selected row with it.
dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
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
    await advance(CONNECTION_QUIET_MS - 100);
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
    await advance(CONNECTION_QUIET_MS - 100);
    expect(element.querySelector(".keys-scroll")).not.toBeNull();
    expect(element.querySelector("[data-connection-chip]")).toBeNull();
    await advance(200);
    expect(element.querySelector("[data-connection-chip]")).not.toBeNull();
    // The list stays; the sentence is the mark's tooltip, not a body in its place.
    expect(element.querySelector(".keys-scroll")).not.toBeNull();
    expect(element.querySelector("[data-connection-chip]")!.getAttribute("title")).toBe(message);
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
    await advance(CONNECTION_QUIET_MS - 100);
    expect(element.querySelector(".pw-row")).not.toBeNull();
    expect(element.querySelector("[data-connection-chip]")).toBeNull();
    await advance(200);
    // Past the bound: a corner mark, and the rows stay (never wiped, never a sentence in their place).
    expect(element.querySelector("[data-connection-chip]")).not.toBeNull();
    expect(element.querySelector(".pw-row")).not.toBeNull();
  });
});

/// One page, one dropped link: what the page shows is the same text before and after the bound
/// (nothing wiped, no sentence in its place), plus the chip, and no chip before the bound.
async function keepsContentWhenDown(
  element: HTMLElement,
  message: string,
  drop: () => Promise<void>,
  connectionOf: () => string,
): Promise<void> {
  const shown = () => element.textContent!.replace(message, "");
  const before = shown();
  expect(before.length).toBeGreaterThan(0);
  await drop();
  expect(connectionOf()).toBe("disconnected");
  await advance(CONNECTION_QUIET_MS - 100);
  expect(element.querySelector("[data-connection-chip]")).toBeNull();
  expect(shown()).toBe(before);
  await advance(200);
  const chip = element.querySelector("[data-connection-chip]");
  expect(chip).not.toBeNull();
  expect(chip!.getAttribute("title")).toBe(message);
  expect(shown()).toBe(before);
}

function sizedForLists() {
  installVirtualSizes(dom.window, (element) => (/scroll|list/.test(element.className) ? 600 : 30));
}

test("History: a lost link keeps the rows and says so only once it lasts", async () => {
  sizedForLists();
  const { HistoryPage } = await import("../history/HistoryPage");
  const { HistoryStore } = await import("../history/store");
  const { MockHistoryProvider } = await import("../history/mockProvider");
  const strings = createStrings((await import("../history/generated/strings.json")).default);
  const provider = new MockHistoryProvider();
  const store = new HistoryStore(provider);
  await mounted(<HistoryPage store={store} strings={strings} />, (element) =>
    keepsContentWhenDown(
      element,
      strings.t("page.disconnected"),
      () =>
        act(async () => {
          provider.page.setConnected(false);
          await settle();
        }),
      () => store.getSnapshot().connection,
    ),
  );
});

test("Stash: a lost link keeps the rows and says so only once it lasts", async () => {
  sizedForLists();
  const { StashPage } = await import("../stash/StashPage");
  const { StashStore } = await import("../stash/store");
  const { MockStashProvider } = await import("../stash/mockProvider");
  const strings = createStrings((await import("../stash/generated/strings.json")).default);
  const provider = new MockStashProvider();
  const store = new StashStore(provider);
  await mounted(<StashPage store={store} strings={strings} />, (element) =>
    keepsContentWhenDown(
      element,
      strings.t("stash.disconnected"),
      () =>
        act(async () => {
          provider.page.setConnected(false);
          await settle();
        }),
      () => store.getSnapshot().connection,
    ),
  );
});

test("Bookmarks: a lost link keeps the rows and says so only once it lasts", async () => {
  sizedForLists();
  const { BookmarksPage } = await import("../bookmarks/BookmarksPage");
  const { BookmarksStore } = await import("../bookmarks/store");
  const { MockBookmarksProvider } = await import("../bookmarks/mockProvider");
  const strings = createStrings((await import("../bookmarks/generated/strings.json")).default);
  const provider = new MockBookmarksProvider();
  const store = new BookmarksStore(provider);
  await mounted(<BookmarksPage store={store} strings={strings} />, (element) =>
    keepsContentWhenDown(
      element,
      strings.t("page.disconnected"),
      () =>
        act(async () => {
          provider.streams.setConnected(false);
          await settle();
        }),
      () => store.getSnapshot().connection,
    ),
  );
});

test("Apps: a lost link keeps the listings and says so only once it lasts", async () => {
  sizedForLists();
  const { AppsPage } = await import("../apps/AppsPage");
  const { AppsStore } = await import("../apps/store");
  const { MockAppsProvider } = await import("../apps/mockProvider");
  const strings = createStrings((await import("../apps/generated/strings.json")).default);
  const provider = new MockAppsProvider();
  const store = new AppsStore(provider);
  await mounted(<AppsPage store={store} strings={strings} />, (element) =>
    keepsContentWhenDown(
      element,
      strings.t("store.disconnected"),
      () =>
        act(async () => {
          provider.page.setConnected(false);
          await settle();
        }),
      () => store.getSnapshot().connection,
    ),
  );
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
    const chip = () => element.querySelector("[data-connection-chip]");
    expect(chip()).toBeNull();
    await advance(CONNECTION_QUIET_MS - 100);
    expect(chip()).toBeNull();
    await advance(200);
    expect(chip()).not.toBeNull();
    expect(chip()!.getAttribute("title")).toBe(message);
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
    await advance(CONNECTION_QUIET_MS - 100);
    expect(element.querySelector("[data-connection-chip]")).toBeNull();
    await advance(200);
    expect(element.querySelector("[data-connection-chip]")).not.toBeNull();
  });
});

// Leo, 2026-11-21: "these messages should not be pushing up the text ... stop layout shifting". The
// mark a lost link leaves is out of flow (jsdom has no layout engine, so the proof is structural: the
// stylesheet that styles the mark fixes it to the viewport, and a page's content has the same DOM
// before and after it comes), and it comes only after the shared 10 s bound.
test("the corner mark takes no room: fixed to the viewport, and the shared 10 s bound holds it", async () => {
  const css = await Bun.file(new URL("../../ui/connectionChip.css", import.meta.url)).text();
  expect(css).toMatch(/\.ui-connection-chip\s*\{[^}]*position:\s*fixed/);
  expect(CONNECTION_QUIET_MS).toBe(10_000);
  const { ReadOnlyNotice } = await import("../settings/components/ReadOnlyBanner");
  await mounted(<ReadOnlyNotice connected={false} loaded readable />, async (element) => {
    await advance(CONNECTION_QUIET_MS + 100);
    const chip = element.querySelector("[data-connection-chip]")!;
    expect(chip).not.toBeNull();
    // Its sentence is the tooltip and the accessible text; nothing of it is a row in the page's flow.
    expect(chip.getAttribute("title")).toBe(chip.textContent);
    expect(element.querySelector(".banner")).toBeNull();
  });
});

test("AutoResumeNotice: the daemon's retry wait says nothing until it has lasted 10 s", async () => {
  const { AutoResumeNotice } = await import("../../agent-session/acpmux/AutoResumeNotice");
  const retry = { retry: { attempt: 2, of: 4, reason: "transport" }, attempt: 1 };
  await mounted(<AutoResumeNotice state={retry} />, async (element) => {
    expect(element.querySelector("[data-auto-resume]")).toBeNull();
    await advance(CONNECTION_QUIET_MS - 100);
    expect(element.querySelector("[data-auto-resume]")).toBeNull();
    await advance(200);
    expect(element.querySelector("[data-auto-resume]")).not.toBeNull();
  });
});

test("AppHealth: a queued action waiting on the link waits 10 s; a stuck part shows at once", async () => {
  const { AppHealthIndicator } = await import("../../app-health/AppHealth");
  const health = createStrings(
    {
      en: {
        "appHealth.pending": "Reconnecting; will %@ when back",
        "appHealth.line.stuck": "%@ isn’t responding",
      },
    },
    ["en"],
  );
  const actions = { open() {}, repair() {} };
  const pending = { worst: "healthy", parts: [], receipts: [], pending: [{ id: "a", label: "close Task" }] };
  await mounted(
    <AppHealthIndicator snapshot={pending as never} strings={health} actions={actions} />,
    async (element) => {
      expect(element.querySelector(".ah-indicator")).toBeNull();
      await advance(CONNECTION_QUIET_MS + 100);
      expect(element.querySelector(".ah-indicator")).not.toBeNull();
    },
  );
  const part = {
    id: "p",
    kind: "page",
    label: "Agent chat",
    state: "stuck",
    sinceMs: 0,
    detail: "",
    action: "none",
    attempt: 0,
    maxAttempts: 3,
    nextAtMs: null,
    canRepair: false,
  };
  const stuck = { worst: "stuck", parts: [part], receipts: [] };
  await mounted(
    <AppHealthIndicator snapshot={stuck as never} strings={health} actions={actions} />,
    async (element) => {
      expect(element.querySelector(".ah-indicator")).not.toBeNull();
    },
  );
});

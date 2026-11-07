// l10n-allow-file: test fixtures.
// Leo 2026-11-07, on the sidebar's "Updated to Nightly" card: "where is the hover for the What's New
// area? Like, if I'm hovering over it ... you hover over it and you get to, like, scroll through the
// thing if you want, right?" / "Like a quick access scroll through of what's new. Right in that bottom
// left of the sidebar area." And: "just update it to Nightly, and then What's New with the up and to
// the right arrow that you can click as a thing".
//
// Resting on the card for the hover dwell opens a scrollable list of the update's changes in the
// card's glass; leaving closes it after a short grace. The sidebar host's word on the pointer wins
// over the page's (WebKit sends no pointer moves while a Chromium window has the key). The page asks
// the host for the room above the card while the preview is open and hands it back once it has
// closed. What's New on the title line, and every row, open the full page.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { ReleaseNotes } from "../src/pages/changelog/types";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import { PreviewIntent, previewEntries, type IntentTimers } from "../src/pages/changelog/updatedPreview";

/** Yields macrotasks until `done` holds, at most `capMs`. */
async function until(done: () => boolean, capMs = 2000) {
  const deadline = Date.now() + capMs;
  while (!done() && Date.now() < deadline) {
    await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  }
}

const data: UpdateHighlights = {
  version: "1.0.0-nightly.4300000000001",
  build: "4300000000001",
  fromVersion: "1.0.0-nightly.4290000000001",
  fromBuild: "4290000000001",
  source: "whatsNew",
  language: "en",
  items: [
    {
      id: "computer-use",
      title: "Computer Use in agent chats",
      summary: "Agents can drive apps on your Mac.",
      category: "new",
    },
    { id: "unread", title: "Unread and Running chats", summary: null, category: "new" },
    { id: "fixes-and-improvements", title: "Fixes and improvements", summary: null, category: "improved" },
  ],
  rest: [{ id: "tabs", title: "Tabs keep their scroll position", summary: null, category: "fixed" }],
  moreCount: 1,
  changelog: { from: "1.0.0-nightly.4290000000001", to: "1.0.0-nightly.4300000000001" },
};

/** Timers a test runs by hand. */
function manualTimers() {
  let now = 0;
  const pending = new Map<number, { at: number; run: () => void }>();
  let next = 1;
  const timers: IntentTimers = {
    set: (run, ms) => {
      const id = next++;
      pending.set(id, { at: now + ms, run });
      return id;
    },
    clear: (handle) => void pending.delete(handle as number),
  };
  const advance = (ms: number) => {
    now += ms;
    for (const [id, timer] of [...pending].sort((a, b) => a[1].at - b[1].at)) {
      if (timer.at > now) continue;
      pending.delete(id);
      timer.run();
    }
  };
  return { timers, advance };
}

describe("the hover intent", () => {
  test("opens after the pointer rests for the dwell, not when it passes over", () => {
    const { timers, advance } = manualTimers();
    const changes: boolean[] = [];
    const intent = new PreviewIntent((open) => changes.push(open), timers, 400, 180);
    intent.page(true);
    advance(200);
    intent.page(false);
    advance(1000);
    expect(changes).toEqual([]);
    intent.page(true);
    advance(399);
    expect(changes).toEqual([]);
    advance(1);
    expect(changes).toEqual([true]);
  });

  test("closes after the grace, and a pointer back within it keeps it open", () => {
    const { timers, advance } = manualTimers();
    const changes: boolean[] = [];
    const intent = new PreviewIntent((open) => changes.push(open), timers, 400, 180);
    intent.page(true);
    advance(400);
    intent.page(false);
    advance(100);
    intent.page(true);
    advance(1000);
    expect(changes).toEqual([true]);
    intent.page(false);
    advance(180);
    expect(changes).toEqual([true, false]);
  });

  test("once the host has spoken, its word wins over the page's stale one", () => {
    const { timers, advance } = manualTimers();
    const changes: boolean[] = [];
    const intent = new PreviewIntent((open) => changes.push(open), timers, 400, 180);
    intent.host(true);
    advance(400);
    expect(changes).toEqual([true]);
    // The page never heard the pointer leave (another window had the key); the host did.
    intent.page(true);
    intent.host(false);
    advance(180);
    expect(changes).toEqual([true, false]);
  });

  test("close() closes at once and cancels a pending open", () => {
    const { timers, advance } = manualTimers();
    const changes: boolean[] = [];
    const intent = new PreviewIntent((open) => changes.push(open), timers, 400, 180);
    intent.page(true);
    advance(400);
    intent.close();
    expect(changes).toEqual([true, false]);
  });
});

describe("the preview's rows", () => {
  test("list the host's items and the rest, without the generic entry", () => {
    const rows = previewEntries(data, undefined, "en");
    expect(rows.map((row) => row.title)).toEqual([
      "Computer Use in agent chats",
      "Unread and Running chats",
      "Tabs keep their scroll position",
    ]);
    expect(rows[0]!.detail).toBe("Agents can drive apps on your Mac.");
  });

  test("list every build of the update's span once its notes load, each change once, internal work left out", () => {
    const span = [
      {
        build: "2",
        shortVersion: "1.0.0-nightly.2",
        date: "2026-11-07",
        highlights: [],
        changes: [],
        items: [{ title: "feat(sidebar): rows keep their color", pr: 5 }],
      },
      {
        build: "1",
        shortVersion: "1.0.0-nightly.1",
        date: "2026-11-06",
        highlights: [],
        changes: [],
        items: [
          { title: "feat(sidebar): rows keep their color", pr: 5 },
          { title: "fix(terminal): paste keeps its spaces", pr: 6 },
          { title: "ci: shard the gallery capture", pr: 7 },
        ],
      },
    ] as unknown as ReleaseNotes[];
    const titles = previewEntries(data, span, "en").map((row) => row.title);
    expect(titles).toEqual(["Rows keep their color", "Paste keeps its spaces"]);
  });
});

describe("the card", () => {
  const scope = globalThis as Record<string, unknown>;
  const keys = [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "IS_REACT_ACT_ENVIRONMENT",
    "ResizeObserver",
    "requestAnimationFrame",
  ] as const;
  const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
  let dom: JSDOM;
  let root: Root | undefined;

  beforeAll(() => {
    dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/updated" });
    const { window } = dom;
    // Layout jsdom does not do: the card's two lines are the composer's 48 px, the list 120 px.
    Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
      configurable: true,
      get(this: HTMLElement) {
        return this.classList.contains("wn-preview-list") ? 120 : 0;
      },
    });
    const rect = window.HTMLElement.prototype.getBoundingClientRect;
    window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
      if (this.classList.contains("wn-card-rest"))
        return { height: 48, width: 236, top: 0, left: 0, right: 236, bottom: 48, x: 0, y: 0, toJSON() {} } as DOMRect;
      return rect.call(this);
    };
    Object.assign(scope, {
      window,
      document: window.document,
      navigator: window.navigator,
      HTMLElement: window.HTMLElement,
      Element: window.Element,
      Node: window.Node,
      IS_REACT_ACT_ENVIRONMENT: true,
      ResizeObserver: class {
        observe() {}
        disconnect() {}
        unobserve() {}
      },
      requestAnimationFrame: () => 0,
    });
  });

  afterAll(() => {
    act(() => root?.unmount());
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  });

  async function render(props: Record<string, unknown>) {
    const { createRoot } = await import("react-dom/client");
    const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/changelog/generated/strings.json")).default;
    act(() => root?.unmount());
    const host = dom.window.document.getElementById("root")!;
    root = createRoot(host);
    const opened: string[] = [];
    await act(async () =>
      root!.render(
        <UpdatedCard
          data={data}
          strings={createStrings(table)}
          actions={{ openChangelog: () => opened.push("open"), dismiss: () => undefined }}
          closeButton={false}
          decoration={null}
          {...props}
        />,
      ),
    );
    return { host, opened };
  }

  test("What's New ↗ sits on the title line and opens the full page", async () => {
    const { host, opened } = await render({});
    const head = host.querySelector(".wn-card-head")!;
    expect(head.querySelector(".wn-card-title")?.textContent).toBe("Updated to Nightly");
    const link = head.querySelector<HTMLButtonElement>(".wn-card-link")!;
    expect(link.textContent).toBe("What's New ↗");
    expect(host.querySelector(".wn-card-primary")).toBeNull();
    await act(async () => link.click());
    expect(opened).toEqual(["open"]);
  });

  test("closed, the card mounts no rows; held open, it lists them and a row opens the full page", async () => {
    let { host, opened } = await render({});
    expect(host.querySelector(".wn-preview")).toBeNull();
    expect(host.querySelector(".wn-card")?.getAttribute("data-preview")).toBe("closed");

    ({ host, opened } = await render({ previewOpen: true }));
    const card = host.querySelector<HTMLElement>(".wn-card")!;
    expect(card.getAttribute("data-preview")).toBe("open");
    expect(card.style.getPropertyValue("--wn-preview-h")).toBe("120px");
    const rows = [...host.querySelectorAll<HTMLButtonElement>(".wn-preview-row")];
    expect(rows.map((row) => row.querySelector(".wn-preview-title")?.textContent)).toEqual([
      "Computer Use in agent chats",
      "Unread and Running chats",
      "Tabs keep their scroll position",
    ]);
    expect(host.querySelector(".wn-preview")?.getAttribute("aria-hidden")).toBe("false");
    await act(async () => rows[1]!.click());
    expect(opened).toEqual(["open"]);
  });

  test("the host's pointer opens it after the dwell, asking for the room above the card, and hands the room back once it has closed", async () => {
    const sizes: number[] = [];
    let host: HTMLElement;
    ({ host } = await render({ hostPointer: false, onPreviewSize: (h: number) => sizes.push(h) }));
    ({ host } = await render({ hostPointer: true, onPreviewSize: (h: number) => sizes.push(h) }));
    const started = Date.now();
    const state = () => host.querySelector(".wn-card")?.getAttribute("data-preview");
    // Warm: the rows are mounted (and measured) before the dwell ends, hidden.
    expect(state()).toBe("closed");
    expect(host.querySelector(".wn-preview")?.getAttribute("aria-hidden")).toBe("true");
    await until(() => state() === "open");
    expect(state()).toBe("open");
    // Not before the dwell (400 ms; a little slack for the timer's granularity).
    expect(Date.now() - started).toBeGreaterThanOrEqual(380);
    // The card's own 48 px and the list's 120 px.
    expect(sizes).toEqual([168]);
  });
});

test("the sidebar's surface reports the preview's room with the card's height, and forwards the host's pointer", async () => {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/updated" });
  const scope = globalThis as Record<string, unknown>;
  Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("wn-preview-list") ? 100 : 0;
    },
  });
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
      unobserve() {}
    },
    requestAnimationFrame: () => 0,
  };
  const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, globals);
  const sizes: { height: number; overlay?: number }[] = [];
  let pointer: ((event: unknown) => void) | undefined;
  const client = {
    call: (op: string, params: unknown) => {
      if (op === "cmux.changelog.surface.get") return Promise.resolve(data);
      if (op === "cmux.changelog.surface.size") {
        sizes.push(params as { height: number; overlay?: number });
        return Promise.resolve(null);
      }
      if (op === "cmux.changelog.list") return Promise.resolve({ builds: [], current: data.version });
      return Promise.reject(new Error(`unavailable ${op}`));
    },
    subscribe: async (stream: string, onEvent: (event: unknown) => void) => {
      if (stream === "cmux.changelog.surface.pointer") pointer = onEvent;
      return () => {};
    },
    handle: () => () => {},
  } as unknown as PageClient;
  try {
    const { mountUpdateSurface } = await import("../src/pages/changelog/surface");
    const host = dom.window.document.getElementById("root")!;
    await act(async () => mountUpdateSurface(host, "updated", client));
    await until(() => sizes.length > 0 && pointer !== undefined);
    expect(sizes.at(-1)?.overlay).toBe(0);
    expect(pointer).toBeDefined();
    const state = () => host.querySelector(".wn-card")?.getAttribute("data-preview");
    await act(async () => pointer!({ inside: true }));
    await until(() => state() === "open");
    expect(state()).toBe("open");
    expect(sizes.at(-1)?.overlay).toBe(100);
    await act(async () => pointer!({ inside: false }));
    await until(() => state() === "closed");
    expect(state()).toBe("closed");
    // The glass closes first; then the room goes back.
    expect(sizes.at(-1)?.overlay).toBe(100);
    await until(() => sizes.at(-1)?.overlay === 0);
    expect(sizes.at(-1)?.overlay).toBe(0);
  } finally {
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});

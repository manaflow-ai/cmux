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
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { ReleaseNotes } from "../src/pages/changelog/types";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import { PreviewIntent, previewEntries, type IntentTimers } from "../src/pages/changelog/updatedPreview";
import { settleReact, teardownDom } from "./support/domTeardown";

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

  test("a pointer back while the close runs reopens at once; after it, the dwell again", () => {
    const { timers, advance } = manualTimers();
    const changes: boolean[] = [];
    const intent = new PreviewIntent((open) => changes.push(open), timers, 400, 180, 265);
    intent.host(true);
    advance(400);
    intent.host(false);
    advance(180);
    expect(changes).toEqual([true, false]);
    advance(100);
    intent.host(true);
    expect(changes).toEqual([true, false, true]);
    intent.host(false);
    advance(180);
    advance(265);
    intent.host(true);
    advance(399);
    expect(changes).toEqual([true, false, true, false]);
    advance(1);
    expect(changes).toEqual([true, false, true, false, true]);
  });

  test("a return after close() (Escape, a click) waits the dwell", () => {
    const { timers, advance } = manualTimers();
    const changes: boolean[] = [];
    const intent = new PreviewIntent((open) => changes.push(open), timers, 400, 180, 265);
    intent.host(true);
    advance(400);
    intent.close();
    intent.host(false);
    intent.host(true);
    expect(changes).toEqual([true, false]);
    advance(400);
    expect(changes).toEqual([true, false, true]);
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

  // Review F1 of #37894: with no build notes the rows come from the host's items, already in the
  // page's language, and the English-only title check let the German generic entry through.
  test("leave out the host's generic entry in any language when the build notes have not loaded", () => {
    const german: UpdateHighlights = {
      ...data,
      language: "de",
      items: [
        {
          id: "fixes-and-improvements",
          title: "Fehlerbehebungen und Verbesserungen",
          summary: null,
          category: "improved",
        },
        { id: "tabs", title: "Tabs behalten ihre Scrollposition", summary: null, category: "improved" },
      ],
      rest: undefined,
      moreCount: 0,
    };
    expect(previewEntries(german, undefined, "de").map((row) => row.title)).toEqual([
      "Tabs behalten ihre Scrollposition",
    ]);
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

  // #37615 F1: the generic entry is known by its source identity (its id and English title), not
  // by the title the page shows; in German it read as a row of its own.
  test("leave out the generic entry in every language", () => {
    const span = [
      {
        build: "1",
        shortVersion: "1.0.0-nightly.1",
        date: "2026-11-06",
        highlights: [],
        changes: [],
        items: [{ title: "fix(terminal): paste keeps its spaces", pr: 6 }],
        whatsNew: {
          version: "1.0.0-nightly.1",
          channel: "nightly",
          date: "2026-11-06",
          headline: { en: "Fixes and improvements" },
          entries: [
            {
              id: "fixes-and-improvements",
              category: "improved",
              title: { en: "Fixes and improvements", de: "Fehlerbehebungen und Verbesserungen" },
              summary: {
                en: "This build brings fixes and improvements. The link lists every change in it.",
                de: "Dieser Build bringt Fehlerbehebungen und Verbesserungen.",
              },
            },
          ],
        },
      },
    ] as unknown as ReleaseNotes[];
    const titles = previewEntries(data, span, "de").map((row) => row.title);
    expect(titles).not.toContain("Fehlerbehebungen und Verbesserungen");
    expect(titles).toEqual(["Paste keeps its spaces"]);
  });

  // #37615 F4: a build with reviewed entries lists those, not its commits too, as the card's summary.
  test("list a build's commits only when it has no reviewed entries", () => {
    const span = [
      {
        build: "2",
        shortVersion: "1.0.0-nightly.2",
        date: "2026-11-07",
        highlights: [],
        changes: [],
        items: [{ title: "feat(sidebar): rows keep their color", pr: 5 }],
        whatsNew: {
          version: "1.0.0-nightly.2",
          channel: "nightly",
          date: "2026-11-07",
          headline: { en: "Sidebar colors" },
          entries: [
            {
              id: "sidebar-colors",
              category: "new",
              title: { en: "Sidebar groups take a palette color" },
              summary: { en: "" },
            },
          ],
        },
      },
      {
        build: "1",
        shortVersion: "1.0.0-nightly.1",
        date: "2026-11-06",
        highlights: [],
        changes: [],
        items: [{ title: "fix(terminal): paste keeps its spaces", pr: 6 }],
      },
    ] as unknown as ReleaseNotes[];
    const titles = previewEntries(data, span, "en").map((row) => row.title);
    expect(titles).toEqual(["Sidebar groups take a palette color", "Paste keeps its spaces"]);
  });

  // #37615 F5: the preview promises every change of the update; none drops off the end.
  test("list every change, however many", () => {
    const items = Array.from({ length: 60 }, (_, index) => ({
      title: `fix(terminal): change number ${index + 1} keeps working`,
      pr: 100 + index,
    }));
    const span = [
      { build: "1", shortVersion: "1.0.0-nightly.1", date: "2026-11-06", highlights: [], changes: [], items },
    ] as unknown as ReleaseNotes[];
    const rows = previewEntries(data, span, "en");
    expect(rows).toHaveLength(60);
    expect(rows.at(-1)!.title).toBe("Change number 60 keeps working");
  });

  // A pull request's changelog sentence restates its title: "Show in Mini points the floating mini
  // at any chat, …" over "Show in Mini points the floating mini at any agent chat (…)". Each line is
  // cut to one line in the preview, so the row read "Show in Mini points the fl…" twice. A row whose
  // second line opens with the title's words shows the title alone; a different line stays.
  test("never show a second line that repeats the title", () => {
    const span = [
      {
        build: "1",
        shortVersion: "1.0.0-nightly.1",
        date: "2026-11-07",
        highlights: [],
        changes: [],
        items: [
          {
            title:
              "cmux NEXT: Show in Mini points the floating mini at any chat, and its reply box keeps typing to it (#37728)",
            pr: 37728,
            description:
              "Show in Mini points the floating mini at any agent chat (chat menu and palette); the mini wears that chat's avatar and state.",
          },
          {
            title: "fix(terminal): paste keeps its spaces (#6)",
            pr: 6,
            description: "Paste keeps its spaces.",
          },
          {
            title: "feat(sidebar): groups take a palette color (#7)",
            pr: 7,
            description: "A new group picks its color from the theme instead of a random pastel.",
          },
        ],
      },
    ] as unknown as ReleaseNotes[];
    const rows = previewEntries(data, span, "en");
    expect(rows.map((row) => [row.title, row.detail])).toEqual([
      ["Show in Mini points the floating mini at any chat, and its reply box keeps typing to it", undefined],
      ["Paste keeps its spaces", undefined],
      ["Groups take a palette color", "A new group picks its color from the theme instead of a random pastel."],
    ]);
  });

  test("drop a host item's second line that repeats its title", () => {
    const host: UpdateHighlights = {
      ...data,
      items: [
        {
          id: "mini",
          title: "Show in Mini points the floating mini at any chat",
          summary: "Show in Mini points the floating mini at any agent chat from the chat menu.",
          category: "new",
        },
      ],
      rest: [],
    };
    expect(previewEntries(host, undefined, "en").map((row) => row.detail)).toEqual([undefined]);
  });

  // A leading article on either line is not a new word: "The host pressure warning…" over "Host
  // pressure warning…" repeats, as the notes' own comparison (model.ts echoKey) reads it.
  test("a leading the, a or an does not hide a repeat", () => {
    const span = [
      {
        build: "1",
        shortVersion: "1.0.0-nightly.1",
        date: "2026-11-07",
        highlights: [],
        changes: [],
        items: [
          {
            title: "fix(sidebar): the host pressure warning names the busy machine (#8)",
            pr: 8,
            description: "Host pressure warning names the busy machine and its load.",
          },
          {
            title: "feat(agent): chat folder opens in Finder (#9)",
            pr: 9,
            description: "A chat folder opens in Finder from the chat menu.",
          },
          {
            title: "fix(sidebar): the sidebar keeps its width (#10)",
            pr: 10,
            description: "Dragging the edge past the window keeps the last width.",
          },
        ],
      },
    ] as unknown as ReleaseNotes[];
    expect(previewEntries(data, span, "en").map((row) => row.detail)).toEqual([
      undefined,
      undefined,
      "Dragging the edge past the window keeps the last width.",
    ]);
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
        return this.classList.contains("wn-preview-body") ? 120 : 0;
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

  afterAll(async () => {
    act(() => root?.unmount());
    await teardownDom(saved, { window: dom.window, scope });
  });

  async function render(props: Record<string, unknown>) {
    const { createRoot } = await import("react-dom/client");
    const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/changelog/generated/strings.json")).default;
    act(() => root?.unmount());
    const host = dom.window.document.getElementById("root")!;
    root = createRoot(host);
    const opened: unknown[] = [];
    await act(async () =>
      root!.render(
        <UpdatedCard
          data={data}
          strings={createStrings(table)}
          actions={{ openChangelog: (target) => opened.push(target ?? "open"), dismiss: () => undefined }}
          closeButton={false}
          decoration={null}
          previewMode="above"
          {...props}
        />,
      ),
    );
    return { host, opened };
  }

  // Lawrence 2026-11-07, "this ui is very bad": What's New beside the title cut it to "Updated to ...".
  // The title line is the title alone; open, the header goes on with the full version and What's New.
  test("the title line is the title alone; open, the header shows the full version and What's New, which opens the full page", async () => {
    const { host, opened } = await render({ previewOpen: true });
    const head = host.querySelector(".wn-card-head")!;
    expect(head.querySelector(".wn-card-title")?.textContent).toBe("Updated to Nightly");
    expect(head.querySelector(".wn-card-link")).toBeNull();
    expect(host.querySelector(".wn-card-primary")).toBeNull();
    expect(host.querySelector(".wn-card-version")?.textContent).toBe(data.version);
    const link = host.querySelector<HTMLButtonElement>(".wn-preview-whatsnew")!;
    expect(link.textContent).toBe("What's New ↗");
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
    // Leo 2026-11-08: "if someone clicks it... maybe just bring them to the section in what's new".
    expect(opened).toEqual([{ area: "agentChat", title: "Unread and Running chats" }]);
  });

  // Leo 2026-11-08: "the sections should be more obvious what's what". Beside the sidebar (the shipped
  // look, UpdatedNotes) the changes stand under their app areas in What's New's order, each header
  // naming the area and its count; What's New opens the page at the top, a row opens it at its change.
  test("beside the sidebar, the changes stand under their areas' headers and a row opens What's New at it", async () => {
    const { createRoot } = await import("react-dom/client");
    const { UpdatedNotes } = await import("../src/pages/changelog/UpdatedNotes");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/changelog/generated/strings.json")).default;
    act(() => root?.unmount());
    const host = dom.window.document.getElementById("root")!;
    root = createRoot(host);
    const opened: unknown[] = [];
    await act(async () =>
      root!.render(
        <UpdatedNotes
          data={data}
          strings={createStrings(table)}
          actions={{ openChangelog: (target) => opened.push(target ?? "open"), dismiss: () => undefined }}
          mode="beside"
        />,
      ),
    );
    const sections = [...host.querySelectorAll<HTMLElement>(".wn-notes-section")];
    expect(sections.map((section) => section.dataset.area)).toEqual(["agentChat", "tabs"]);
    expect(sections.map((section) => section.querySelector(".wn-notes-area-name")?.textContent)).toEqual([
      "Agent Chat",
      "Tabs",
    ]);
    expect(sections.map((section) => section.querySelector(".wn-notes-area-count")?.textContent)).toEqual(["2", "1"]);
    expect(sections[0]!.querySelectorAll(".wn-notes-row")).toHaveLength(2);
    act(() => host.querySelector<HTMLButtonElement>(".wn-notes-whatsnew")!.click());
    act(() => sections[0]!.querySelectorAll<HTMLButtonElement>(".wn-notes-row")[1]!.click());
    expect(opened).toEqual(["open", { area: "agentChat", title: "Unread and Running chats" }]);
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

  // #37615 F2: with motion reduced or off the preview has no close transition to wait for, so the
  // room goes back as the preview closes.
  test("with motion reduced, the room goes back as the preview closes", async () => {
    const page = dom.window.document.documentElement;
    page.dataset.cmuxMotion = "reduced";
    try {
      const sizes: number[] = [];
      let host: HTMLElement;
      ({ host } = await render({ hostPointer: false, onPreviewSize: (h: number) => sizes.push(h) }));
      ({ host } = await render({ hostPointer: true, onPreviewSize: (h: number) => sizes.push(h) }));
      const state = () => host.querySelector(".wn-card")?.getAttribute("data-preview");
      await until(() => state() === "open");
      expect(sizes).toEqual([168]);
      // The same card hears the pointer leave (render() would mount a new one).
      const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
      const { createStrings } = await import("../src/pages/shared/i18n");
      const table = (await import("../src/pages/changelog/generated/strings.json")).default;
      await act(async () =>
        root!.render(
          <UpdatedCard
            data={data}
            strings={createStrings(table)}
            actions={{ openChangelog: () => undefined, dismiss: () => undefined }}
            closeButton={false}
            decoration={null}
            previewMode="above"
            hostPointer={false}
            onPreviewSize={(h: number) => sizes.push(h)}
          />,
        ),
      );
      await until(() => state() === "closed");
      expect(state()).toBe("closed");
      expect(sizes).toEqual([168, 0]);
    } finally {
      delete page.dataset.cmuxMotion;
    }
  });

  // Review F2 of #37790 at efe59289: a drag closed the open preview but handed its room back only
  // after the close (240 ms), so the native host shrank and moved the held card's view mid-drag.
  // Review F4 of #37790: the card with the theme's doodle decoration had no press listener, rest box or
  // anchor, so it could not be dragged.
  // Review of #38020 at 2b1e9834: the press listener was attached to the card's node once, so a live
  // theme switch between the plain card and the doodle one replaced the node and the new card did not drag.
  test("a card that switches to the doodle decoration while shown still drags", async () => {
    const moves: number[] = [];
    const drag = {
      place: () => ({ anchor: "bottom" as const, above: 400, below: 0 }),
      move: (offset: { x: number; y: number }) => moves.push(offset.y),
      drop: () => undefined,
      dismiss: () => undefined,
    };
    const { host } = await render({ drag });
    expect(host.querySelector(".wn-updated")).not.toBeNull();
    // The theme switches live: the same card, now with the doodle decoration.
    const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/changelog/generated/strings.json")).default;
    await act(async () =>
      root!.render(
        <UpdatedCard
          data={data}
          strings={createStrings(table)}
          actions={{ openChangelog: () => undefined, dismiss: () => undefined }}
          closeButton={false}
          decoration="doodle"
          animate={false}
          drag={drag}
        />,
      ),
    );
    const card = host.querySelector<HTMLElement>('.wn-card[data-decoration="doodle"]')!;
    expect(card).not.toBeNull();
    const pointer = (type: string, y: number, target: EventTarget) => {
      const event = new dom.window.MouseEvent(type, {
        bubbles: true,
        button: 0,
        buttons: type === "pointerup" ? 0 : 1,
        clientX: 100,
        clientY: y,
        screenX: 100,
        screenY: y,
      });
      Object.defineProperty(event, "pointerId", { value: 1 });
      target.dispatchEvent(event);
    };
    await act(async () => pointer("pointerdown", 60, card.querySelector(".wn-card-note")!));
    await act(async () => pointer("pointermove", 20, dom.window));
    expect(moves).toEqual([-40]);
    await act(async () => pointer("pointerup", 20, dom.window));
  });

  test("the doodle-decorated card drags too, and says where it rests", async () => {
    const moves: number[] = [];
    const drag = {
      place: () => ({ anchor: "top" as const, above: 0, below: 400 }),
      move: (offset: { x: number; y: number }) => moves.push(offset.y),
      drop: () => undefined,
      dismiss: () => undefined,
    };
    const { host } = await render({ decoration: "doodle", animate: false, anchor: "top", drag });
    const card = host.querySelector<HTMLElement>('.wn-card[data-decoration="doodle"]')!;
    expect(card.getAttribute("data-anchor")).toBe("top");
    expect(card.hasAttribute("data-drags")).toBe(true);
    const pointer = (type: string, y: number, target: EventTarget) => {
      const event = new dom.window.MouseEvent(type, {
        bubbles: true,
        button: 0,
        buttons: type === "pointerup" ? 0 : 1,
        clientX: 100,
        clientY: y,
        screenX: 100,
        screenY: y,
      });
      Object.defineProperty(event, "pointerId", { value: 1 });
      target.dispatchEvent(event);
    };
    await act(async () => pointer("pointerdown", 20, card.querySelector(".wn-card-note")!));
    await act(async () => pointer("pointermove", 60, dom.window));
    expect(moves).toEqual([40]);
    expect(card.hasAttribute("data-dragging")).toBe(true);
    await act(async () => pointer("pointerup", 60, dom.window));
  });

  test("a drag that starts with the preview open hands its room back at once", async () => {
    const sizes: number[] = [];
    const moves: number[] = [];
    const drag = {
      place: () => ({ anchor: "bottom" as const, above: 400, below: 0 }),
      move: (offset: { x: number; y: number }) => moves.push(offset.y),
      drop: () => undefined,
      dismiss: () => undefined,
    };
    let host: HTMLElement;
    ({ host } = await render({ hostPointer: false, drag, onPreviewSize: (h: number) => sizes.push(h) }));
    ({ host } = await render({ hostPointer: true, drag, onPreviewSize: (h: number) => sizes.push(h) }));
    const state = () => host.querySelector(".wn-card")?.getAttribute("data-preview");
    await until(() => state() === "open");
    expect(sizes).toEqual([168]);
    const pointer = (type: string, y: number, target: EventTarget) => {
      const event = new dom.window.MouseEvent(type, {
        bubbles: true,
        button: 0,
        buttons: 1,
        clientX: 100,
        clientY: y,
        screenX: 100,
        screenY: y,
      });
      Object.defineProperty(event, "pointerId", { value: 1 });
      target.dispatchEvent(event);
    };
    await act(async () => pointer("pointerdown", 20, host.querySelector(".wn-card-note")!));
    await act(async () => pointer("pointermove", -20, dom.window));
    expect(moves.length).toBeGreaterThan(0);
    expect(sizes).toEqual([168, 0]);
    await act(async () => pointer("pointerup", -20, dom.window));
  });
});

/** Mounts the sidebar's Updated surface in a DOM of its own and runs `body` with it. */
async function withSurface(
  body: (surface: {
    dom: JSDOM;
    host: HTMLElement;
    sizes: { height: number; overlay?: number; preview?: number }[];
    ops: string[];
    pointer: (event: unknown) => void;
    state: () => string | null | undefined;
  }) => Promise<void>,
) {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/updated" });
  const scope = globalThis as Record<string, unknown>;
  Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("wn-preview-body") ? 100 : 0;
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
  const sizes: { height: number; overlay?: number; preview?: number }[] = [];
  const ops: string[] = [];
  let pointer: ((event: unknown) => void) | undefined;
  const client = {
    call: (op: string, params: unknown) => {
      ops.push(op);
      if (op === "cmux.changelog.surface.get") return Promise.resolve(data);
      if (op === "cmux.changelog.surface.size") {
        sizes.push(params as { height: number; overlay?: number; preview?: number });
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
    // The in-card preview is the look before the popover beside the sidebar: the host sends it in
    // the theme's slot (UpdatedCardPreviewMode `above`).
    dom.window.document.documentElement.setAttribute("data-cmux-decoration-updated-card-preview", "above");
    await act(async () => mountUpdateSurface(host, "updated", client));
    await until(() => sizes.length > 0 && pointer !== undefined);
    expect(pointer).toBeDefined();
    const state = () => host.querySelector(".wn-card")?.getAttribute("data-preview");
    await body({ dom, host, sizes, ops, pointer: (event) => pointer!(event), state });
  } finally {
    await settleReact();
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
}

test("the sidebar's surface reports the preview's room with the card's height, and forwards the host's pointer", async () => {
  await withSurface(async ({ sizes, pointer, state }) => {
    expect(sizes.at(-1)?.overlay).toBe(0);
    await act(async () => pointer({ inside: true }));
    await until(() => state() === "open");
    expect(state()).toBe("open");
    expect(sizes.at(-1)?.overlay).toBe(100);
    await act(async () => pointer({ inside: false }));
    await until(() => state() === "closed");
    expect(state()).toBe("closed");
    // The glass closes first; then the room goes back.
    expect(sizes.at(-1)?.overlay).toBe(100);
    await until(() => sizes.at(-1)?.overlay === 0);
    expect(sizes.at(-1)?.overlay).toBe(0);
  });
});

// Leo 2026-11-08: "it turns from glass when it's unhovered into opaque when it does get hovered". The
// host draws the card's glass behind the page; the page says the open preview's height as its motion
// starts and 0 as its close starts, before the room goes back, so the glass runs the same motion.
test("the sidebar's surface says the open preview's height for the host's glass as the motion starts", async () => {
  await withSurface(async ({ sizes, pointer, state }) => {
    expect(sizes.at(-1)?.preview).toBe(0);
    await act(async () => pointer({ inside: true }));
    await until(() => state() === "open");
    expect(sizes.at(-1)).toMatchObject({ overlay: 100, preview: 100 });
    await act(async () => pointer({ inside: false }));
    await until(() => state() === "closed");
    // The glass starts closing with the page; the room is still there until the close has run.
    expect(sizes.at(-1)).toMatchObject({ overlay: 100, preview: 0 });
    await until(() => sizes.at(-1)?.overlay === 0);
    expect(sizes.at(-1)?.preview).toBe(0);
  });
});

// Leo 2026-11-08: "the animation also seems like it's a little bit slow". The preview opens on the
// card's own curve, a fast start that settles long, the native glass's twin (Motion+AppKit.swift
// cardCurve and cardDuration), and the room goes back once that motion has run.
test("the preview opens on the card's curve, 180ms, the native glass's twin", () => {
  const css = readFileSync(new URL("../src/pages/changelog/updateSurfaces.css", import.meta.url), "utf8");
  expect(css).toContain("--wn-preview-motion: 180ms;");
  expect(css).toContain("--wn-preview-ease: cubic-bezier(0.16, 1, 0.3, 1);");
  expect(css).toMatch(/\.wn-preview \{\s*transition: height var\(--wn-preview-motion\) var\(--wn-preview-ease\);/);
  const tsx = readFileSync(new URL("../src/pages/changelog/updatedPreview.ts", import.meta.url), "utf8");
  expect(tsx).toContain("export const PREVIEW_CLOSE_MS = 180;");
  const swift = readFileSync(
    new URL("../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Motion/Motion+AppKit.swift", import.meta.url),
    "utf8",
  );
  expect(swift).toContain("CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)");
  expect(swift).toContain("cardDuration: TimeInterval = 0.18");
});

// Review F2 of #37615: a preview the host's hover opened has no focus inside the card, so Escape
// reaches only the document; it closes the preview, and only a second Escape dismisses the card.
test("Escape on a hover-opened preview closes the preview, not the card", async () => {
  await withSurface(async ({ dom, ops, pointer, state }) => {
    await act(async () => pointer({ inside: true }));
    await until(() => state() === "open");
    expect(state()).toBe("open");
    const escape = () =>
      dom.window.document.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
      );
    await act(async () => void escape());
    await until(() => state() === "closed");
    expect(state()).toBe("closed");
    expect(ops).not.toContain("cmux.changelog.surface.dismiss");
    await act(async () => void escape());
    expect(ops).toContain("cmux.changelog.surface.dismiss");
  });
});

// Review F2 of #38332: a click on a row opens What's New under the row's area, so the list must file
// each change where the page does: a curated change by its title, else by what its summary adds; a
// commit by its subject's label. Every shipped nightly's rows agree with the page's.
test("the preview files each change under the area What's New files it", async () => {
  const { sheetRows } = await import("../src/pages/changelog/SheetPage");
  const { mergedView } = await import("../src/pages/changelog/model");
  const nightlies = (await import("../src/pages/changelog/fixtures/nightly-next-50.json")).default as ReleaseNotes[];
  let compared = 0;
  const mismatches: string[] = [];
  for (const build of nightlies) {
    const page = new Map(sheetRows(mergedView([build], "en")).map((row) => [row.title, row.area]));
    for (const row of previewEntries(data, [build], "en")) {
      if (!page.has(row.title)) continue;
      compared++;
      if (page.get(row.title) !== row.area)
        mismatches.push(`${build.build}: ${row.title} (${row.area} vs ${page.get(row.title)})`);
    }
  }
  expect(compared).toBeGreaterThan(50);
  expect(mismatches).toEqual([]);
});

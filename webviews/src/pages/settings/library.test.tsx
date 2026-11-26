// Appearance > Customization Library: every entry `cmux customize library` lists, top first,
// with its switch and its order; where two entries that are on set the same key, the lower one says
// in words which higher one wins and on what; a change runs the CLI's verb and draws the library it
// answers; a refusal (a preview is open) shows the CLI's own words and changes nothing.
import { afterAll, afterEach, expect, setSystemTime, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockOptions } from "./mockProvider";
import type { Rendered } from "./testing";
import { installVirtualSizes } from "../../../test/support/virtualSizes";
import { settingsCardSizes } from "../../../test/support/settingsCardSizes";

const restore = installDom();
afterAll(() => restore());
// The card's rows are windowed: give the page a viewport and its rows a height, as a browser would.
installVirtualSizes({ HTMLElement: globalThis.window.HTMLElement }, settingsCardSizes);
const { renderPage, settle, click, run } = await import("./testing");
const { mockEmptyLibrary, mockLongLibrary, relist, runLibrary, mockLibrary } = await import("./mockLibrary");
const { beatenByEntry } = await import("./customizeLibrary");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="customizeLibrary"]');
const entry = (name: string) => card()!.querySelector<HTMLElement>(`[data-library-entry="${name}"]`)!;
const names = () =>
  [...card()!.querySelectorAll<HTMLElement>("[data-library-entry]")].map((row) => row.dataset.libraryEntry);
const action = (name: string, which: string) =>
  entry(name).querySelector<HTMLButtonElement>(`[data-library-action="${which}"]`)!;
const toggle = (name: string) => entry(name).querySelector<HTMLButtonElement>('[role="switch"]')!;

async function open(mock?: MockOptions) {
  page = await renderPage({ path: "/settings/appearance", mock });
  await settle();
  return page;
}

test("the engine's rule: the higher entry that is on wins, and an entry that is off loses nothing", () => {
  const listing = mockLibrary();
  expect(listing.conflicts.map((c) => [c.key, c.winner, c.losers])).toEqual([
    ["appearance.metrics.sidebarWidth", "night", ["roomy"]],
  ]);
  // paper is off: it sets appearance.theme as night does, yet nothing conflicts on it.
  expect(beatenByEntry(listing).get("roomy")).toEqual([{ winner: "night", keys: ["appearance.metrics.sidebarWidth"] }]);
  expect(beatenByEntry(listing).has("paper")).toBe(false);
  const flipped = runLibrary(listing, { verb: "order", name: "roomy", position: "top" })!;
  expect(beatenByEntry(flipped).get("night")).toEqual([{ winner: "roomy", keys: ["appearance.metrics.sidebarWidth"] }]);
  expect(relist([]).conflicts).toEqual([]);
});

test("Appearance lists the library top first, each entry with its switch", async () => {
  await open();
  expect(card()).not.toBeNull();
  expect(names()).toEqual(["night", "roomy", "pr-widget", "vim-keys", "paper"]);
  expect(toggle("night").getAttribute("aria-checked")).toBe("true");
  expect(toggle("paper").getAttribute("aria-checked")).toBe("false");
  expect(entry("night").textContent).toContain("a darker theme at night");
});

test("a conflict says which entry wins and on what, under the one that loses", async () => {
  await open();
  const beaten = entry("roomy").querySelector<HTMLElement>("[data-library-beaten]")!;
  expect(beaten.dataset.libraryBeaten).toBe("night");
  expect(beaten.textContent).toBe("night is higher and wins: appearance.metrics.sidebarWidth");
  expect(entry("night").querySelector("[data-library-beaten]")).toBeNull();
});

test("turning an entry off runs `customize library off` and draws the answer: the conflict goes", async () => {
  await open();
  await click(toggle("night"));
  await settle();
  expect(page!.provider.libraryRuns).toEqual([{ verb: "off", name: "night" }]);
  expect(toggle("night").getAttribute("aria-checked")).toBe("false");
  expect(entry("roomy").querySelector("[data-library-beaten]")).toBeNull();
});

test("Move Up and Move Down run `customize library order` by one; the top has no Move Up", async () => {
  await open();
  expect(action("night", "up").disabled).toBe(true);
  expect(action("paper", "down").disabled).toBe(true);
  await click(action("roomy", "up"));
  await settle();
  expect(page!.provider.libraryRuns).toEqual([{ verb: "order", name: "roomy", position: "1" }]);
  expect(names().slice(0, 2)).toEqual(["roomy", "night"]);
  // Now roomy is higher: night is the one told it loses.
  expect(entry("night").querySelector<HTMLElement>("[data-library-beaten]")!.dataset.libraryBeaten).toBe("roomy");
});

test("Remove asks first, inline, then runs `customize library remove`", async () => {
  await open();
  await click(action("paper", "remove"));
  await settle();
  expect(page!.provider.libraryRuns).toEqual([]);
  const confirm = card()!.querySelector<HTMLElement>("[data-library-confirm]")!;
  expect(confirm.textContent).toContain("Remove paper?");
  await click(confirm.querySelector('[data-library-action="confirmRemove"]')!);
  await settle();
  expect(page!.provider.libraryRuns).toEqual([{ verb: "remove", name: "paper" }]);
  expect(names()).not.toContain("paper");
  expect(card()!.querySelector("[data-library-confirm]")).toBeNull();
});

test("a refused toggle (a preview is open) shows the CLI's words and changes nothing", async () => {
  await open({ libraryRefusal: "a preview is open: apply or discard it first" });
  await click(toggle("night"));
  await settle();
  expect(page!.provider.libraryRuns).toEqual([{ verb: "off", name: "night" }]);
  expect(card()!.querySelector("[data-library-refusal]")!.textContent).toBe(
    "Not changed: a preview is open: apply or discard it first",
  );
  expect(toggle("night").getAttribute("aria-checked")).toBe("true");
});

const listed = () => page!.provider.log.filter((call) => call.op === "cmux.settings.customize.library").length;

test("nothing applied yet: the library was read and no card draws (the person hasn't opted in)", async () => {
  await open({ library: mockEmptyLibrary() });
  expect(listed()).toBeGreaterThan(0);
  expect(card()).toBeNull();
});

test("fifty entries draw in order, each row with its place among all fifty", async () => {
  await open({ library: mockLongLibrary(50) });
  // The rows near the viewport mount (cardWindow.ts), and the first and last always.
  const rows = [...card()!.querySelectorAll<HTMLElement>("[data-library-entry]")];
  expect(rows.length).toBeLessThan(50);
  expect(names()[0]).toBe("look-01");
  expect(names().at(-1)).toBe("look-50");
  const places = rows.map((row) => Number(row.getAttribute("aria-posinset")));
  expect(places).toEqual([...places].sort((a, b) => a - b));
  expect(rows.map((row) => row.dataset.libraryEntry)).toEqual(
    places.map((at) => `look-${String(at).padStart(2, "0")}`),
  );
  expect(rows.every((row) => row.getAttribute("aria-setsize") === "50")).toBe(true);
});

test("a host with no CLI draws no card and no error", async () => {
  await open({ failing: { "cmux.settings.customize.library": "cmux.page.unavailable" } });
  expect(listed()).toBeGreaterThan(0);
  expect(card()).toBeNull();
});

test("a list read a toggle overtakes doesn't draw the old switch back over the toggle's answer", async () => {
  await open();
  let release = () => {};
  page!.provider.libraryReadHold = new Promise<void>((resolve) => (release = resolve));
  // Back on Appearance past the section's fresh time: the library is read again in the
  // background, and that read (held) sees night on.
  setSystemTime(new Date(Date.now() + 60_000));
  try {
    const before = listed();
    await run(() => page!.history.push("/settings/general"));
    await run(() => page!.history.push("/settings/appearance"));
    await settle();
    expect(listed()).toBeGreaterThan(before);
    expect(toggle("night").disabled).toBe(false);
    await click(toggle("night"));
    await settle();
    expect(page!.provider.libraryRuns).toEqual([{ verb: "off", name: "night" }]);
    expect(toggle("night").getAttribute("aria-checked")).toBe("false");
    release();
    await settle();
    expect(toggle("night").getAttribute("aria-checked")).toBe("false");
    expect(entry("roomy").querySelector("[data-library-beaten]")).toBeNull();
  } finally {
    release();
    setSystemTime();
  }
});

async function scrolledWhile(body: (scrolled: HTMLElement[]) => Promise<void>) {
  const view = globalThis.window.HTMLElement.prototype;
  const original = view.scrollIntoView;
  const scrolled: HTMLElement[] = [];
  view.scrollIntoView = function (this: HTMLElement) {
    scrolled.push(this);
  };
  try {
    await body(scrolled);
  } finally {
    view.scrollIntoView = original;
  }
}

test("?focus=card.customizeLibrary opens Appearance scrolled to the library", async () => {
  await scrolledWhile(async (scrolled) => {
    page = await renderPage({ path: "/settings/appearance?focus=card.customizeLibrary" });
    await settle();
    expect(card()).not.toBeNull();
    expect(scrolled).toContain(card()!);
    page.unmount();
    page = null;
    scrolled.length = 0;
    await open();
    expect(scrolled).not.toContain(card()!);
  });
});

test("with fifty entries, Remove on an early row scrolls its confirmation into view and focuses Cancel", async () => {
  await scrolledWhile(async (scrolled) => {
    await open({ library: mockLongLibrary(50) });
    await click(action("look-02", "remove"));
    await settle();
    const confirm = card()!.querySelector<HTMLElement>("[data-library-confirm]")!;
    expect(confirm.textContent).toContain("Remove look-02?");
    expect(scrolled).toContain(confirm);
    expect(document.activeElement).toBe(confirm.querySelector('[data-library-action="cancel"]'));
    expect(page!.provider.libraryRuns).toEqual([]);
  });
});

test("a try-on that reverts reads the library again, so the entry it turned on shows off", async () => {
  const tried = mockLibrary();
  await open({
    library: tried,
    tryOn: {
      generation: 7,
      revert_to: 6,
      started_ms: Date.now() - 60_000,
      expires_ms: Date.now() + 5 * 60_000,
      label: "profile night",
      origin: "cli",
    },
  });
  expect(toggle("night").getAttribute("aria-checked")).toBe("true");
  // The engine's revert turns the try-on's entry off in the library it lists.
  page!.provider.library = runLibrary(tried, { verb: "off", name: "night" })!;
  await click(page!.container.querySelector<HTMLElement>("[data-try-on-revert]")!);
  await settle();
  expect(toggle("night").getAttribute("aria-checked")).toBe("false");
});

// A `pr-N` entry (`cmux customize use pr:N`): an unmerged PR's web layer. Leo, 2026-11-14: "it's
// obviously not going to show anything and not affect anything when there's nothing to toggle on and
// off" and "I want people to not accidentally soft lock themselves and like have good recovery options".
const { mockLibraryWithExperiments, PR_ON, PR_MERGED, PR_NATIVE } = await import("./mockLibrary");
const { experimentsOn, entryDetail } = await import("./customizeLibrary");

test("with no PR entry the card draws exactly as before: no PR row, nothing counts as an experiment", async () => {
  const listing = mockLibrary();
  expect(experimentsOn(listing)).toEqual([]);
  expect(experimentsOn(null)).toEqual([]);
  expect(experimentsOn(mockEmptyLibrary())).toEqual([]);
  // A PR entry that is off is not an experiment that is on: the mark counts nothing.
  expect(experimentsOn(mockLibraryWithExperiments([]))).toEqual([]);
  await open();
  expect(card()!.querySelector("[data-library-code]")).toBeNull();
  expect(card()!.querySelector("[data-library-pr-link], [data-library-needs-build], [data-library-note]")).toBeNull();
  // Each entry without `code` keeps its own name as its title and the detail line it had before
  // (`entryDetail`), with no PR line under it.
  for (const item of listing.entries) {
    const row = entry(item.name);
    expect(row.querySelector(".row-title")!.textContent).toBe(item.name);
    expect(row.textContent).toContain(entryDetail(item));
    expect(row.querySelector(".font-mono")).toBeNull();
  }
});

test("a PR row names the PR, its short head, a link to it, what needs a build and the refresh's note", async () => {
  await open({ library: mockLibraryWithExperiments() });
  expect(names().slice(0, 3)).toEqual(["pr-43543", "pr-43496", "pr-43410"]);
  const row = entry("pr-43543");
  expect(row.dataset.libraryCode).toBe("43543");
  expect(row.querySelector(".row-title")!.textContent).toBe(`#43543 ${PR_ON.title}`);
  expect(row.querySelector("[data-library-head]")!.textContent).toBe("716063c");
  expect(row.querySelector<HTMLAnchorElement>("[data-library-pr-link]")!.getAttribute("href")).toBe(
    "https://github.com/manaflow-ai/cmux/pull/43543",
  );
  expect(row.querySelector("[data-library-needs-build]")!.textContent).toBe(
    "Needs a build: Swift in CmuxNextSidebar (the sidebar footer)",
  );
  expect(toggle("pr-43543").getAttribute("aria-checked")).toBe("true");
  // A refresh turned the merged PR off and said why.
  expect(entry("pr-43496").querySelector("[data-library-note]")!.textContent).toBe(PR_MERGED.note!);
  expect(toggle("pr-43496").getAttribute("aria-checked")).toBe("false");
  // No web part: nothing a running app can take, so it cannot be turned on; its line says why.
  expect(toggle("pr-43410").disabled).toBe(true);
  expect(entry("pr-43410").querySelector("[data-library-needs-build]")!.textContent).toBe(
    `Needs a build: ${PR_NATIVE.needs_build![0]}`,
  );
});

test("a PR row's switch runs `customize library off` through the host, as every entry's does", async () => {
  await open({ library: mockLibraryWithExperiments() });
  await click(toggle("pr-43543"));
  await settle();
  expect(page!.provider.libraryRuns).toEqual([{ verb: "off", name: "pr-43543" }]);
  expect(toggle("pr-43543").getAttribute("aria-checked")).toBe("false");
  expect(experimentsOn(page!.provider.library)).toEqual([]);
});

test("a PR row's Remove asks first, then runs `customize library remove` through the host", async () => {
  await open({ library: mockLibraryWithExperiments() });
  await click(action("pr-43543", "remove"));
  await settle();
  expect(page!.provider.libraryRuns).toEqual([]);
  await click(card()!.querySelector('[data-library-confirm] [data-library-action="confirmRemove"]')!);
  await settle();
  expect(page!.provider.libraryRuns).toEqual([{ verb: "remove", name: "pr-43543" }]);
  expect(names()).not.toContain("pr-43543");
});

test("two PRs on: the lower one says the higher one's pages are in use, in words", async () => {
  await open({ library: mockLibraryWithExperiments([PR_ON, PR_MERGED]) });
  const beaten = entry("pr-43496").querySelector<HTMLElement>("[data-library-beaten]")!;
  expect(beaten.dataset.libraryBeaten).toBe("pr-43543");
  expect(beaten.textContent).toBe("pr-43543 is higher: its pages are in use");
});

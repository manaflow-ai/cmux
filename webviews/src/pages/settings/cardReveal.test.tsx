// A route that names a windowed card (cardWindow.ts) opens the page on it: the card scrolls itself
// into view once its window is ready (the list found the page's scroller and its rows are drawn),
// and the window's start never scrolls the page back. Review of #46364, F1: the card revealed itself
// in its first commit, before its window had a scroller or a row, and the next commit's window took
// the page's scroller over and wrote back the offset it had read before (0): a deep link to
// card.customizeLibrary left the page at the top of Personalization.
// Keys is windowed too but no route reveals it (it leads its own category; categories.ts routeCard).
// The browser lane checks the place the card lands (test/settings-card-reveal-browser.test.ts).
import { afterAll, afterEach, expect, setSystemTime, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";
import { installVirtualSizes } from "../../../test/support/virtualSizes";
import { installCardRects, settingsCardSizes } from "../../../test/support/settingsCardSizes";

const restore = installDom();
afterAll(() => {
  setSystemTime();
  restore();
});
installVirtualSizes({ HTMLElement: globalThis.window.HTMLElement }, settingsCardSizes);
installCardRects({ HTMLElement: globalThis.window.HTMLElement });
const { renderPage } = await import("./testing");
const { manyShares } = await import("../../../test/support/settingsCardFixtures");
const { mockLongLibrary } = await import("./mockLibrary");

const NOW = new Date(2026, 10, 18, 10, 0).getTime();
setSystemTime(new Date(NOW));

/** Where the browser's scrollIntoView puts the page for the card (any offset away from the top). */
const REVEALED = 4_000;

let page: Rendered | null = null;
const original = globalThis.window.HTMLElement.prototype.scrollIntoView;
afterEach(() => {
  page?.unmount();
  page = null;
  globalThis.window.HTMLElement.prototype.scrollIntoView = original;
});

const cards = [
  {
    name: "Customization Library",
    card: "customizeLibrary",
    path: "/settings/personalization?focus=card.customizeLibrary",
    row: "[data-library-entry]",
    setup: (provider: Rendered["provider"]) => (provider.library = mockLongLibrary(600)),
  },
  {
    name: "Shared Links",
    card: "sharedLinks",
    path: "/settings/privacy?focus=card.sharedLinks",
    row: "[data-shared-link]",
    setup: (provider: Rendered["provider"]) => (provider.shares = manyShares(600, NOW)),
  },
];

for (const card of cards) {
  test(`${card.name}: its deep link reveals the card once its rows are drawn, and the page stays there`, async () => {
    // The rows the card had mounted each time it revealed itself; the reveal scrolls the page as a
    // browser does (the offset moves, a scroll event says so).
    const revealedWith: number[] = [];
    globalThis.window.HTMLElement.prototype.scrollIntoView = function (this: HTMLElement) {
      if (this.dataset.card !== card.card) return;
      revealedWith.push(this.querySelectorAll(card.row).length);
      const scroller = this.closest<HTMLElement>("main.content")!;
      scroller.scrollTop = REVEALED;
      scroller.dispatchEvent(new globalThis.window.Event("scroll"));
    };
    page = await renderPage({ path: card.path, setup: card.setup });
    const scroller = page.container.querySelector<HTMLElement>("main.content")!;
    expect(revealedWith.length).toBeGreaterThan(0);
    // Never before the window has drawn rows.
    expect(revealedWith.every((rows) => rows > 0)).toBe(true);
    // The window's start (and every commit after) left the page where the reveal put it.
    expect(scroller.scrollTop).toBe(REVEALED);
  });
}

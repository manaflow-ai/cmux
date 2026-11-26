// Shared Links and Keys mount only the rows near the viewport (cardWindow.ts), yet Tab and Shift-Tab
// go through their rows in list order as when every row was mounted: the focused row's neighbours
// and the first and last rows stay mounted, so the browser's own next tab stop is the next row. And a
// Keys row whose Revoke is asking first stays mounted, so a scroll away and back keeps it asking.
// Tab here is the browser's rule, emulated: the next (or previous) focusable element in DOM order.
import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";
import { installVirtualSizes } from "../../../test/support/virtualSizes";
import { installCardRects, settingsCardSizes } from "../../../test/support/settingsCardSizes";

const restore = installDom();
afterAll(() => restore());
installVirtualSizes({ HTMLElement: globalThis.window.HTMLElement }, settingsCardSizes);
installCardRects({ HTMLElement: globalThis.window.HTMLElement });
const { renderPage, settle, click } = await import("./testing");
const { manyKeys, manyShares } = await import("../../../test/support/settingsCardFixtures");
const { mockLongLibrary } = await import("./mockLibrary");

const NOW = Date.now();
const COUNT = 1_000;

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const FOCUSABLE =
  'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])';

/** The browser's Tab (or Shift-Tab): focus moves to the next (previous) focusable element in DOM order. */
async function tab(back = false) {
  // A control's own tabindex="-1" (a switch's hidden checkbox) is no tab stop.
  const stops = [...document.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((element) => element.tabIndex >= 0);
  const at = stops.indexOf(document.activeElement as HTMLElement);
  const next = stops[at + (back ? -1 : 1)];
  if (!next) throw new Error("no tab stop there");
  await act(async () => next.focus());
}

/** The row (its place in the whole list) holding focus, or null. */
const focusedRow = () => {
  const row = (document.activeElement as HTMLElement | null)?.closest<HTMLElement>("[data-index]");
  return row ? Number(row.dataset.index) : null;
};

const scroller = () => page!.container.querySelector<HTMLElement>("main.content")!;
async function scrollTo(top: number) {
  await act(async () => scroller().scrollTo({ top }));
  await settle();
}

const cards = [
  {
    name: "Shared Links",
    path: "/settings/privacy",
    card: '[data-card="sharedLinks"]',
    first: "[data-shared-link-action=revoke]",
    last: "[data-shared-link-action=revoke]",
    fill: (provider: Rendered["provider"]) => (provider.shares = manyShares(COUNT, NOW)),
  },
  {
    name: "Keys",
    path: "/settings/keys",
    card: '[data-card="keys"]',
    first: '[data-key-action="revoke"]',
    last: '[data-key-action="revoke"]',
    fill: (provider: Rendered["provider"]) => provider.setKeys(manyKeys(COUNT, NOW)),
  },
  {
    name: "Customization Library",
    path: "/settings/personalization",
    card: '[data-card="customizeLibrary"]',
    // A row's tab stops: Move Up, Move Down, Remove, then its switch.
    first: '[data-library-action="up"]',
    last: '[role="switch"]',
    fill: (provider: Rendered["provider"]) => (provider.library = mockLongLibrary(COUNT)),
  },
];

for (const card of cards) {
  const stop = (index: number, which: string) =>
    page!.container.querySelector<HTMLElement>(`${card.card} [data-index="${index}"] ${which}`)!;

  /** Focuses the row's last tab stop (Tab goes on from it) or its first (Shift-Tab goes back from it). */
  async function focusThenScrollAway(index: number, which: string) {
    page = await renderPage({ path: card.path, setup: card.fill });
    await settle();
    await act(async () => stop(index, which).focus());
    expect(focusedRow()).toBe(index);
    await scrollTo(40_000);
    // The window is far from the focused row now.
    expect(page.container.querySelector(`${card.card} [data-index="${index + 20}"]`)).toBeNull();
  }

  test(`${card.name}: Tab from a focused row the page scrolled away from lands on the next row`, async () => {
    await focusThenScrollAway(3, card.last);
    await tab();
    expect(focusedRow()).toBe(4);
  });

  test(`${card.name}: Shift-Tab from a focused row the page scrolled away from lands on the previous row`, async () => {
    await focusThenScrollAway(3, card.first);
    await tab(true);
    expect(focusedRow()).toBe(2);
  });

  test(`${card.name}: Shift-Tab into the card from the control after it lands on the last row`, async () => {
    page = await renderPage({ path: card.path, setup: card.fill });
    await settle();
    // The first tab stop after the card's rows, in DOM order.
    const rows = page.container.querySelector(`${card.card} .rows`)!;
    const after = [...document.querySelectorAll<HTMLElement>(FOCUSABLE)].find(
      (element) => rows.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING && !rows.contains(element),
    );
    // Keys is the last card on its page: the page's next control stands in for one after it.
    const control = after ?? rows.parentElement!.parentElement!.appendChild(document.createElement("button"));
    await act(async () => control.focus());
    await tab(true);
    expect(focusedRow()).toBe(COUNT - 1);
  });
}

test("Keys: a row whose Revoke is asking first keeps asking after the page scrolls 10,000 px away and back", async () => {
  page = await renderPage({ path: "/settings/keys", setup: (provider) => provider.setKeys(manyKeys(COUNT, NOW)) });
  await settle();
  const row = () => page!.container.querySelector<HTMLElement>('[data-card="keys"] [data-index="3"]');
  await click(row()!.querySelector('[data-key-action="revoke"]')!);
  expect(row()!.querySelector("[data-key-confirm]")).not.toBeNull();
  // Nothing in the row holds focus: only the open confirmation keeps it.
  await act(async () => (document.activeElement as HTMLElement | null)?.blur());
  await scrollTo(10_000);
  await scrollTo(0);
  expect(row()!.querySelector("[data-key-confirm]")).not.toBeNull();
});

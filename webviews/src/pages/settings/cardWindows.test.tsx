// Shared Links and Keys grow with the person's data and have no cap (the daemon's share list, `cmux
// keys ls`), so each mounts only the rows near the page's viewport (cardWindow.ts), and a row draws
// again only when its own share or key changed: not when another one does, not on a scroll step and
// not on a new reading of the clock (visible-only rules 1 and 2).
import { act } from "react";
import { afterAll, afterEach, expect, setSystemTime, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";
import { installVirtualSizes } from "../../../test/support/virtualSizes";
import {
  installCardRects,
  KEY_HEIGHT,
  LIBRARY_HEIGHT,
  SHARED_LINK_HEIGHT,
  settingsCardSizes,
} from "../../../test/support/settingsCardSizes";
import { rowPropsRenders } from "../../../test/support/rowPropsRenders";

const restore = installDom();
afterAll(() => {
  setSystemTime();
  restore();
});
installVirtualSizes({ HTMLElement: globalThis.window.HTMLElement }, settingsCardSizes);
installCardRects({ HTMLElement: globalThis.window.HTMLElement });
const { renderPage, settle, click } = await import("./testing");
const { manyKeys, manyShares } = await import("../../../test/support/settingsCardFixtures");
const { SHARES_KEY, KEYS_KEY, LIBRARY_KEY } = await import("./sectionQueries");
const { mockLongLibrary, runLibrary } = await import("./mockLibrary");

// 10:00 local time: a minute later is the same day.
const NOW = new Date(2026, 10, 18, 10, 0).getTime();
setSystemTime(new Date(NOW));

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

/** The most rows an 800 px page mounts: the viewport and 12 rows of overscan each side. */
const bound = (height: number) => Math.ceil(800 / height) + 2 * 12 + 1;

const cards = [
  {
    name: "Shared Links",
    path: "/settings/privacy",
    rows: () => page!.container.querySelectorAll('[data-card="sharedLinks"] [data-shared-link]'),
    height: SHARED_LINK_HEIGHT,
    key: SHARES_KEY,
    fill: (count: number) => (provider: Rendered["provider"]) => (provider.shares = manyShares(count, NOW)),
    // Share 5 gains a guest.
    changeOne: (provider: Rendered["provider"]) => {
      const shares = provider.shares!.shares!.map((share, index) =>
        index === 5
          ? { ...share, guests: [{ guest_id: "new", name: "Robin", joined_at: NOW, state: "active" }] }
          : share,
      );
      provider.shares = { ...provider.shares!, shares };
    },
    // Revoke All asks first: the card draws again on its own state.
    redraw: () => click(page!.container.querySelector('[data-shared-links-action="revokeAll"]')!),
  },
  {
    name: "Keys",
    path: "/settings/keys",
    rows: () => page!.container.querySelectorAll('[data-card="keys"] [data-key]'),
    height: KEY_HEIGHT,
    key: KEYS_KEY,
    fill: (count: number) => (provider: Rendered["provider"]) => provider.setKeys(manyKeys(count, NOW)),
    // Key 5 is used somewhere new.
    changeOne: (provider: Rendered["provider"]) => {
      const keys = provider.keys.keys.map((key, index) =>
        index === 5 ? { ...key, uses: [{ target: "deploy.example.com", count: 1 }] } : key,
      );
      provider.setKeys({ ...provider.keys, keys });
    },
    // Revoke on the first row asks first: the row's own state, the card's list unchanged.
    redraw: () => click(page!.container.querySelector('[data-card="keys"] [data-key-action="revoke"]')!),
  },
  {
    // The engine holds at most 500 entries (cmux-customize library.rs MAX_ENTRIES), past the 100 a
    // list may draw whole; the window is checked here at any length.
    name: "Customization Library",
    path: "/settings/personalization",
    rows: () => page!.container.querySelectorAll('[data-card="customizeLibrary"] [data-library-entry]'),
    height: LIBRARY_HEIGHT,
    key: LIBRARY_KEY,
    fill: (count: number) => (provider: Rendered["provider"]) => (provider.library = mockLongLibrary(count)),
    // Entry 5 (every third entry is off) turns on, as another window's `cmux customize library on` would.
    changeOne: (provider: Rendered["provider"]) => {
      provider.library = runLibrary(provider.library, { verb: "on", name: provider.library.entries[5]!.name })!;
    },
    // Remove on the first row asks first: the card draws again on its own state.
    redraw: () =>
      click(page!.container.querySelector('[data-card="customizeLibrary"] [data-library-action="remove"]')!),
  },
];

for (const card of cards) {
  test(`${card.name}: 1,000 and 10,000 rows mount the same few rows near the viewport`, async () => {
    const mounted: number[] = [];
    const setSizes: (string | null)[] = [];
    for (const count of [1_000, 10_000]) {
      page = await renderPage({ path: card.path, setup: card.fill(count) });
      await settle();
      mounted.push(card.rows().length);
      setSizes.push(card.rows()[0]?.getAttribute("aria-setsize") ?? null);
      page.unmount();
      page = null;
    }
    expect(mounted[0]).toBeGreaterThan(0);
    expect(mounted[0]).toBeLessThanOrEqual(bound(card.height));
    expect(mounted[1]).toBe(mounted[0]);
    // Screen readers still hear each row's place in the whole list.
    expect(setSizes).toEqual(["1000", "10000"]);
  });

  test(`${card.name}: one changed row, a scroll step and a later clock draw no other row again`, async () => {
    page = await renderPage({ path: card.path, setup: card.fill(1_000) });
    await settle();
    const renders = rowPropsRenders(card.rows);
    const scroller = page.container.querySelector<HTMLElement>("main.content")!;

    // One share or key changes and the list is read again: only its row draws.
    renders.mark();
    card.changeOne(page.provider);
    await act(async () => page!.store.queryClient.invalidateQueries({ queryKey: card.key }));
    await settle();
    expect(renders.since()).toBe(1);

    // One row's scroll step: the rows still mounted do not draw again.
    renders.mark();
    await act(async () => scroller.scrollTo({ top: scroller.scrollTop + card.height }));
    await settle();
    expect(renders.since()).toBe(0);
    await act(async () => scroller.scrollTo({ top: 0 }));
    await settle();

    // A minute later, the card draws again on its own state: the rows do not.
    setSystemTime(new Date(NOW + 60_000));
    renders.mark();
    await card.redraw();
    await settle();
    expect(renders.since()).toBeLessThanOrEqual(card.name === "Keys" ? 1 : 0);
    setSystemTime(new Date(NOW));
  });
}

test("Customization Library: a toggle draws its own row again and no other, while the change runs and after", async () => {
  page = await renderPage({
    path: "/settings/personalization",
    setup: (provider) => (provider.library = mockLongLibrary(1_000)),
  });
  await settle();
  const rows = () => page!.container.querySelectorAll('[data-card="customizeLibrary"] [data-library-entry]');
  const renders = rowPropsRenders(rows);
  renders.mark();
  await click(page.container.querySelector('[data-card="customizeLibrary"] [data-index="5"] [role="switch"]')!);
  await settle();
  // Entry 5 was off (every third entry is).
  expect(page.container.querySelector('[data-card="customizeLibrary"] [data-index="5"]')!.hasAttribute("data-on")).toBe(
    true,
  );
  expect(renders.since()).toBe(1);
});

test("Shared Links: a revoke in flight disables every Revoke and draws no row again", async () => {
  page = await renderPage({
    path: "/settings/privacy",
    setup: (provider) => (provider.shares = manyShares(1_000, NOW)),
  });
  await settle();
  const rows = () => page!.container.querySelectorAll('[data-card="sharedLinks"] [data-shared-link]');
  const buttons = () => [
    ...page!.container.querySelectorAll<HTMLButtonElement>(
      '[data-card="sharedLinks"] [data-shared-link-action="revoke"]',
    ),
  ];
  // The revoke waits until the test lets it answer, and ends nothing, so the list read after it is
  // the same list: only `busy` changes, on and off.
  let answer: () => void = () => {};
  page.store.revokeShares = () => new Promise((resolve) => (answer = () => resolve(null)));
  const renders = rowPropsRenders(rows);
  renders.mark();
  await click(buttons()[5]!);
  await settle();
  expect(buttons().every((button) => button.disabled)).toBe(true);
  expect(renders.since()).toBe(0);
  await act(async () => answer());
  await settle();
  expect(buttons().some((button) => button.disabled)).toBe(false);
  expect(renders.since()).toBe(0);
});

// Settings cards that list what the host sends draw again only the rows that changed (visible-only
// rule 2). Both lists here are capped by their host, so they are not windowed: the device activity
// at 8 lines (DeviceDirectory's `device audit --limit 8`) and Browse More Art at 12 works per
// collection (MuseumArtSearch's `limit`). A keystroke, a host change or a new line must not draw the
// rows already there again.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MuseumArtResult } from "./ops";

/**
 * Rows under `elements` drawn again since `mark`. React stores the props of each host element's
 * latest commit on its DOM node (`__reactProps$`): a render that reaches the row makes a new props
 * object, and a row React skipped (a memo row, or JSX the React Compiler kept) keeps it. This reads
 * the row's own element, not a component above it, so a row drawn inline by a parent that
 * re-rendered on its own state counts too: test/support/mountedRowRenders reads a component's
 * props, which stay the same object then.
 */
function rowRenders(elements: () => Iterable<Element>) {
  const propsOf = (element: Element) => {
    const key = Object.keys(element).find((name) => name.startsWith("__reactProps$"));
    return key ? (element as unknown as Record<string, unknown>)[key] : undefined;
  };
  let seen = new Set<unknown>();
  return {
    mark() {
      seen = new Set(Array.from(elements(), propsOf));
    },
    since() {
      return Array.from(elements()).filter((element) => !seen.has(propsOf(element))).length;
    },
  };
}

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const activity = (count: number, from = 0) =>
  Array.from({ length: count }, (_, index) => ({
    time: new Date(Date.UTC(2026, 9, 22, 7, 59 - from - index)).toISOString(),
    what: index % 2 ? "Removed" : "Added",
    subject: `mini-${from + index}`,
  }));

test("device activity: a host change, a Remove click and a new line draw no line already shown again", async () => {
  const page = await renderPage({ path: "/settings/machines" });
  const host = () => page.provider.host;
  await act(async () =>
    page.provider.setHost({ ...host(), devices: { ...host().devices!, activity: activity(8, 1) } }),
  );
  await settle();
  const lines = () => page.container.querySelectorAll("[data-device-activity] > .row");
  expect(lines().length).toBe(8);
  const renders = rowRenders(lines);

  renders.mark();
  await act(async () => page.provider.setHost({ ...host(), machines: host().machines.slice(0, 0) }));
  await settle();
  expect(renders.since()).toBe(0);

  renders.mark();
  await act(async () => page.container.querySelector<HTMLButtonElement>('[data-remove-device="peer:mini-7"]')!.click());
  expect(renders.since()).toBe(0);

  // The newest line arrives first and the oldest drops (the host keeps 8): only the new one draws.
  renders.mark();
  await act(async () =>
    page.provider.setHost({
      ...host(),
      devices: { ...host().devices!, activity: [...activity(1, 0), ...activity(8, 1).slice(0, 7)] },
    }),
  );
  await settle();
  expect(lines().length).toBe(8);
  expect(lines()[0]!.textContent).toContain("mini-0");
  expect(renders.since()).toBe(1);
  page.unmount();
});

const works: MuseumArtResult[] = Array.from({ length: 36 }, (_, index) => ({
  key: `aic:${index}`,
  title: `Water Lilies ${index}`,
  artist: "Claude Monet",
  date: "1906",
  source: "Art Institute of Chicago",
  page: `https://www.artic.edu/artworks/${index}`,
}));

test("Browse More Art: typing and a search answering the same works draw no tile again", async () => {
  const page = await renderPage({ path: "/settings/personalization?part=background", mock: { museumArt: works } });
  const open = Array.from(page.container.querySelectorAll<HTMLButtonElement>('[data-card="backdrop"] button')).find(
    (button) => button.hasAttribute("aria-expanded"),
  )!;
  await act(async () => open.click());
  const browser = page.container.querySelector<HTMLElement>('[data-card="art-browser"]')!;
  const field = browser.querySelector<HTMLInputElement>('input[type="search"]')!;
  const type = async (value: string) => {
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      setter.call(field, value);
      field.dispatchEvent(new Event("input", { bubbles: true }));
    });
  };
  const submit = async () => {
    await act(async () => browser.querySelector("form")!.requestSubmit());
    await settle();
  };
  await type("monet");
  await submit();
  const tiles = () => browser.querySelectorAll(".backdrop-grid > .backdrop-tile");
  expect(tiles().length).toBe(36);
  const renders = rowRenders(tiles);

  renders.mark();
  await type("monet water");
  expect(renders.since()).toBe(0);

  renders.mark();
  await submit();
  expect(tiles().length).toBe(36);
  expect(renders.since()).toBe(0);
  page.unmount();
});

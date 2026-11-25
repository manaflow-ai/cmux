// cmuxterm-hq#7442 row 1: Settings opened at Machines (`#/settings/machines`: `cmux settings
// machines`, `openSettings section=machines`, the `card.machines` deep link) showed the top of
// Accounts, since Machines is a card of the Accounts category. The route that names the card
// lands on it: the card is scrolled to the top in the commit that draws it, before the first
// paint, so the first frame is already Machines.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, run } = await import("./testing");

type Scroll = { card: string | null; block: string | undefined };
const scrolls: Scroll[] = [];
const view = globalThis.window.HTMLElement.prototype;
const original = view.scrollIntoView;
view.scrollIntoView = function (this: HTMLElement, arg?: boolean | ScrollIntoViewOptions) {
  scrolls.push({ card: this.dataset.card ?? null, block: typeof arg === "object" ? arg.block : undefined });
};
afterAll(() => {
  view.scrollIntoView = original;
});

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
  scrolls.length = 0;
});

const machineScrolls = () => scrolls.filter((scroll) => scroll.card === "machines");

test("Settings opened at Machines lands on the Machines card, not the top of Accounts", async () => {
  page = await renderPage({ path: "/settings/machines" });
  expect(page.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("accounts");
  expect(page.container.querySelector('[data-card="machines"]')).not.toBeNull();
  expect(machineScrolls()).toEqual([{ card: "machines", block: "start" }]);
});

test("Settings opened at Accounts stays at its top", async () => {
  page = await renderPage({ path: "/settings/accounts" });
  expect(machineScrolls()).toEqual([]);
});

test("a route the host opens on a kept page moves to Machines, also from Accounts", async () => {
  page = await renderPage({ path: "/settings/general" });
  await run(() => page!.history.push("/settings/machines"));
  expect(machineScrolls()).toEqual([{ card: "machines", block: "start" }]);
  scrolls.length = 0;
  await run(() => page!.history.push("/settings/accounts"));
  expect(machineScrolls()).toEqual([]);
  await run(() => page!.history.push("/settings/machines"));
  expect(machineScrolls()).toEqual([{ card: "machines", block: "start" }]);
});

test("the card.machines deep link names the card too", async () => {
  page = await renderPage({ path: "/settings/accounts?focus=card.machines" });
  expect(machineScrolls()).toEqual([{ card: "machines", block: "start" }]);
});

// Settings on TanStack Router (Lawrence 2026-10-21, msg 8948): a section link preloads its section
// on hover (the router's intent preload runs the section route's loader), the click then reads
// nothing again, and the sidebar search lives in the route (`?q=`, `?changed=1`).
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, run, click, changeValue, ops, settle } = await import("./testing");
const { act } = await import("react");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const link = (page: Rendered, section: string) =>
  page.container.querySelector<HTMLElement>(`[data-section-link="${section}"]`)!;
const shown = (page: Rendered) => page.container.querySelector("[data-section]")?.getAttribute("data-section");
const actionReads = (page: Rendered, section: string) =>
  ops(page.provider, "cmux.settings.section.actions").filter(
    (params) => (params as { section?: string }).section === section,
  ).length;

/** The pointer entering `element`, as WebKit sends it (React's onMouseEnter reads `mouseover`). */
async function hover(element: Element): Promise<void> {
  await act(async () => {
    element.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true, relatedTarget: null }));
  });
}

/** Yields macrotasks until `done` holds (the router's intent preload waits its short delay). */
async function until(done: () => boolean): Promise<void> {
  for (let turn = 0; turn < 400 && !done(); turn += 1) await settle();
  expect(done()).toBe(true);
}

test("hovering a section link reads that section's host data before any click", async () => {
  page = await renderPage({ path: "/settings/general" });
  expect(actionReads(page, "advanced")).toBe(0);
  await hover(link(page, "advanced"));
  await until(() => actionReads(page!, "advanced") === 1);
  // A preload changes nothing on screen.
  expect(shown(page)).toBe("general");
});

test("a click on a hovered section draws its buttons with no second read", async () => {
  page = await renderPage({ path: "/settings/general" });
  await hover(link(page, "advanced"));
  await until(() => actionReads(page!, "advanced") === 1);
  await click(link(page, "advanced"));
  expect(shown(page)).toBe("advanced");
  expect(
    page.container.querySelector('[data-section-actions="advanced"] [data-action="reloadConfiguration"]'),
  ).not.toBeNull();
  expect(actionReads(page, "advanced")).toBe(1);
});

test("a section opened by its route draws its buttons from the route's loader", async () => {
  page = await renderPage({ path: "/settings/general" });
  await run(() => page!.history.push("/settings/advanced"));
  expect(shown(page)).toBe("advanced");
  expect(page.container.querySelector('[data-action="reloadConfiguration"]')).not.toBeNull();
  // The loader's read is the one the card shows; mounting the card reads nothing more.
  expect(actionReads(page, "advanced")).toBe(1);
});

test("the search text and the Changed filter are the route's search", async () => {
  page = await renderPage({ path: "/settings/general" });
  const field = page.container.querySelector<HTMLInputElement>("input[data-settings-search]")!;
  await changeValue(field, "font");
  expect(new URLSearchParams(page.history.location.search).get("q")).toBe("font");
  await click(page.container.querySelector("[data-changed-only]")!);
  expect(new URLSearchParams(page.history.location.search).get("changed")).toBe("1");
  // Typing adds no history entries: Back leaves the search for the page before it.
  await click(link(page, "appearance"));
  expect(shown(page)).toBe("appearance");
  expect(field.value).toBe("");
  await run(() => page!.history.back());
  expect(new URLSearchParams(page.history.location.search).get("q")).toBe("font");
  expect(field.value).toBe("font");
});

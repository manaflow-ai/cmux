// Settings > Sidebar > Archived Workspaces (cmux#51635): the sidebar draws no archived workspace, so this
// card lists them in sidebar order with Open, Restore and Delete, like ChatGPT's Settings > Data controls >
// Archived chats. Open keeps the row (it stays archived); Restore takes it out of the list; Delete asks
// first, inline, and Cancel keeps it.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockSettingsProvider } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");
const { archivedDetail } = await import("./components/ArchivedWorkspacesCard");

const scrolled: string[] = [];
const view = globalThis.window.HTMLElement.prototype;
const original = view.scrollIntoView;
view.scrollIntoView = function (this: HTMLElement) {
  if (this.dataset.card) scrolled.push(this.dataset.card);
};
afterAll(() => {
  view.scrollIntoView = original;
});

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
  scrolled.length = 0;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="archivedWorkspaces"]')!;
const rowKeys = () => [...card().querySelectorAll<HTMLElement>("[data-archived]")].map((row) => row.dataset.archived);
const button = (row: string, action: string) =>
  card().querySelector<HTMLButtonElement>(`[data-archived="${row}"] [data-archived-action="${action}"]`)!;

async function open(setup?: (provider: MockSettingsProvider) => void, path = "/settings/sidebar") {
  page = await renderPage({ path, setup });
  await settle();
  return page;
}

test("Settings > Sidebar lists every archived row in sidebar order, with where it sits", async () => {
  await open();
  expect(rowKeys()).toEqual(["workspace:ws-archived-1", "workspace:ws-archived-2", "item:itm-archived-link"]);
  const grouped = card().querySelector<HTMLElement>('[data-archived="workspace:ws-archived-2"]')!;
  expect(grouped.textContent).toContain("Release notes draft");
  expect(grouped.querySelector("[data-archived-detail]")!.textContent).toBe("Docs · This Mac");
  const link = card().querySelector<HTMLElement>('[data-archived="item:itm-archived-link"]')!;
  expect(link.querySelector("[data-archived-detail]")!.textContent).toBe("Link");
});

test("Open shows it and keeps the row; Restore puts it back and the row leaves", async () => {
  await open();
  await click(button("workspace:ws-archived-1", "open"));
  await settle();
  expect(page!.provider.archivedRuns).toEqual([{ action: "open", kind: "workspace", id: "ws-archived-1" }]);
  expect(rowKeys()).toContain("workspace:ws-archived-1");
  await click(button("workspace:ws-archived-1", "restore"));
  await settle();
  expect(page!.provider.archivedRuns.at(-1)).toEqual({ action: "restore", kind: "workspace", id: "ws-archived-1" });
  expect(rowKeys()).toEqual(["workspace:ws-archived-2", "item:itm-archived-link"]);
});

test("Delete asks first; Cancel keeps it, confirming closes it", async () => {
  await open();
  await click(button("workspace:ws-archived-2", "delete"));
  expect(card().querySelector('[data-archived-confirm="workspace:ws-archived-2"]')).not.toBeNull();
  expect(page!.provider.archivedRuns).toEqual([]);
  await click(card().querySelector<HTMLButtonElement>('[data-archived-action="cancel"]')!);
  expect(card().querySelector("[data-archived-confirm]")).toBeNull();
  expect(rowKeys()).toContain("workspace:ws-archived-2");
  await click(button("workspace:ws-archived-2", "delete"));
  await click(card().querySelector<HTMLButtonElement>('[data-archived-action="confirmDelete"]')!);
  await settle();
  expect(page!.provider.archivedRuns).toEqual([{ action: "delete", kind: "workspace", id: "ws-archived-2" }]);
  expect(rowKeys()).toEqual(["workspace:ws-archived-1", "item:itm-archived-link"]);
});

test("nothing archived: one line; no window: one line", async () => {
  await open((provider) => {
    provider.archived = { available: true, rows: [] };
  });
  expect(card().querySelector("[data-archived-empty]")!.textContent).toBe("You have no archived workspaces.");
  page!.unmount();
  await open((provider) => {
    provider.archived = { available: false };
  });
  expect(card().querySelector("[data-archived-unavailable]")).not.toBeNull();
  expect(rowKeys()).toEqual([]);
});

test("the card deep link opens Settings > Sidebar at Archived Workspaces", async () => {
  await open(undefined, "/settings/sidebar?focus=card.archivedWorkspaces");
  expect(page!.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("sidebar");
  expect(scrolled).toEqual(["archivedWorkspaces"]);
});

test("the detail line: group and computer, nothing for a loose row with no computer", () => {
  expect(archivedDetail({ kind: "workspace", id: "a", title: "A", group: "G", machine: "M" })).toBe("G · M");
  expect(archivedDetail({ kind: "workspace", id: "a", title: "A", group: null, machine: null })).toBe("");
});

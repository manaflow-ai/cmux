// Settings search takes a wish: when no setting matches, the same box offers "Ask cmux to do this",
// which opens the Customize chat with `/customize WORDS` (`customize.open`, cmux#43304).
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, fire, renderPage } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const search = (page: Rendered) => page.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
const ask = (page: Rendered) => page.container.querySelector<HTMLElement>("[data-ask-cmux]");

test("a search no setting matches offers Ask cmux to do this with the words", async () => {
  page = await renderPage();
  await changeValue(search(page), "font");
  expect(ask(page)).toBeNull();
  await changeValue(search(page), "show my   PRs in the sidebar");
  const row = ask(page)!;
  expect(row).not.toBeNull();
  expect(row.textContent).toContain("Ask cmux to do this");
  expect(row.textContent).toContain("show my   PRs in the sidebar");
});

test("Ask cmux to do this opens the Customize chat with /customize and the words", async () => {
  page = await renderPage();
  await changeValue(search(page), "show my PRs in the sidebar");
  await click(ask(page)!);
  expect(page.provider.actionsRun).toEqual([
    { action: "customize.open", args: { draft: "/customize show my PRs in the sidebar" } },
  ]);
});

test("Return with no match asks cmux; Return with a match reveals it and asks nothing", async () => {
  page = await renderPage();
  await changeValue(search(page), "font");
  await fire(search(page), "keydown", { key: "Enter" });
  expect(page.provider.actionsRun).toEqual([]);
  await changeValue(search(page), "add a weather widget");
  await fire(search(page), "keydown", { key: "Enter" });
  expect(page.provider.actionsRun).toEqual([
    { action: "customize.open", args: { draft: "/customize add a weather widget" } },
  ]);
});

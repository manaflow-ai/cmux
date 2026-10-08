import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { mockManagedKey } from "./mockProvider";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage, rowElement } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

/** Right-clicks a row's title and answers the menu that opened. */
async function openMenu(rendered: Rendered, key: string): Promise<HTMLElement> {
  const title = rowElement(rendered.container, key).querySelector(".row-title")!;
  await act(async () => {
    title.dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 60 }));
  });
  const menu = rowElement(rendered.container, key).querySelector<HTMLElement>("[role=menu]");
  if (!menu) throw new Error(`no menu opened on ${key}`);
  return menu;
}

const item = (menu: HTMLElement, label: string) =>
  [...menu.querySelectorAll<HTMLButtonElement>("[role=menuitem]")].find((button) => button.textContent === label);

describe("a setting row's context menu", () => {
  test("offers Copy Setting Key, then Reset to Default after a separator", async () => {
    page = await renderPage({ path: "/settings/privacy" });
    const menu = await openMenu(page, "history.terminalCommands");
    expect([...menu.querySelectorAll("[role=menuitem]")].map((button) => button.textContent)).toEqual([
      "Copy Setting Key",
      "Reset to Default",
    ]);
    expect(menu.querySelectorAll("hr").length).toBe(1);
  });

  test("Copy Setting Key writes the row's cmux.json key to the pasteboard", async () => {
    page = await renderPage({ path: "/settings/privacy" });
    await click(item(await openMenu(page, "history.terminalCommands"), "Copy Setting Key")!);
    expect(ops(page.provider, "cmux.app.clipboard.write")).toEqual([{ text: "history.terminalCommands" }]);
    expect(page.provider.clipboard).toBe("history.terminalCommands");
  });

  test("Reset to Default is off at the default and resets a changed value", async () => {
    page = await renderPage({ path: "/settings/privacy" });
    const key = "history.terminalCommands";
    expect(item(await openMenu(page, key), "Reset to Default")!.disabled).toBe(true);
    await click(rowElement(page.container, key).querySelector("[role=switch]")!);
    await click(item(await openMenu(page, key), "Reset to Default")!);
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key }]);
  });

  test("a managed setting cannot be reset from the menu", async () => {
    page = await renderPage({ path: "/settings/browser" });
    expect(item(await openMenu(page, mockManagedKey), "Reset to Default")!.disabled).toBe(true);
  });
});

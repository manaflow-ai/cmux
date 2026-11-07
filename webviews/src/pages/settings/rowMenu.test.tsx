import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import type { PopupHost } from "../../ui/popupHost";
import { mockManagedKey } from "./mockProvider";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage, rowElement, settle } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

/** Right-clicks a row's title and answers the menu that opened. */
async function openMenu(rendered: Rendered, key: string): Promise<HTMLElement> {
  const title = rowElement(rendered.container, key).querySelector(".row-title")!;
  await act(async () => {
    title.dispatchEvent(
      new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 60 }),
    );
  });
  const menu = document.querySelector<HTMLElement>("[role=menu]");
  if (!menu) throw new Error(`no menu opened on ${key}`);
  return menu;
}

const item = (menu: HTMLElement, label: string) =>
  [...menu.querySelectorAll<HTMLButtonElement>("[role=menuitem]")].find((button) => button.textContent === label);

function nativePopupHost(shown: Record<string, unknown>[]) {
  const listeners = new Set<(event: Record<string, unknown>) => void>();
  const host = {
    show: async () => ({ shown: true }),
    update() {},
    hide() {},
    owner: () => null,
    listen: () => () => {},
    native: {
      show: async (model: Record<string, unknown>) => {
        shown.push(model);
        return { shown: true };
      },
      update() {},
      hide() {},
      listen(listener: (event: Record<string, unknown>) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    },
    emit(event: Record<string, unknown>) {
      listeners.forEach((listener) => listener(event));
    },
  };
  return host;
}

describe("a setting row's context menu", () => {
  test("sends the row menu as native rows without mounting a DOM menu", async () => {
    const shown: Record<string, unknown>[] = [];
    const host = nativePopupHost(shown);
    page = await renderPage({ path: "/settings/privacy", popupHost: host as unknown as PopupHost });
    const title = rowElement(page.container, "history.terminalCommands").querySelector(".row-title")!;
    await act(async () => {
      title.dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 60 }),
      );
    });
    await settle();
    expect(shown).toHaveLength(1);
    expect(shown[0].rows).toEqual([
      { kind: "action", id: "copyKey", label: "Copy Setting Key" },
      { kind: "separator", id: "separator:reset", label: "" },
      { kind: "action", id: "reset", label: "Reset to Default", disabled: true },
    ]);
    expect(document.querySelector("[role=menu]")).toBeNull();
    await act(async () => {
      host.emit({
        type: "pick",
        popupId: shown[0].id,
        revision: shown[0].revision,
        id: "copyKey",
      });
    });
    await settle();
    expect(page.provider.clipboard).toBe("history.terminalCommands");
  });

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

  // cx-dmnf (nxdog77-v1): the menu opened about 340 px right of the pointer. A category's enter
  // animation (`.section`, fill mode both) keeps a transform on it, and WebKit then makes it the
  // containing block of fixed descendants, so a fixed menu inside it is offset by the category
  // column's position. The menu lives at the document root and sits at the pointer.
  test("opens at the pointer, outside the animated category", async () => {
    page = await renderPage({ path: "/settings/privacy" });
    const menu = await openMenu(page, "history.terminalCommands");
    expect(menu.closest(".section")).toBeNull();
    expect(page.container.contains(menu)).toBe(false);
    expect([menu.style.left, menu.style.top]).toEqual(["40px", "60px"]);
  });

  test("a managed setting cannot be reset from the menu", async () => {
    page = await renderPage({ path: "/settings/browser" });
    expect(item(await openMenu(page, mockManagedKey), "Reset to Default")!.disabled).toBe(true);
  });
});

// cx-64hi (nxdog77-v1): the Theme page's own rows (Match System Appearance, the theme pickers, the
// app theme) opened no menu, unlike every other setting title. They offer the same menu for the
// setting they edit.
describe("the Theme page rows' context menu", () => {
  async function openThemeMenu(rendered: Rendered, row: string): Promise<HTMLElement> {
    const title = rendered.container.querySelector(`[data-theme-row="${row}"] .row-title`);
    if (!title) throw new Error(`no theme row ${row}`);
    await act(async () => {
      title.dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 60 }),
      );
    });
    const menu = document.querySelector<HTMLElement>("[role=menu]");
    if (!menu) throw new Error(`no menu opened on theme row ${row}`);
    return menu;
  }

  test.each([
    ["match", "appearance.theme"],
    ["single", "appearance.theme"],
    ["app", "appearance.appTheme"],
  ])("the %s row copies %s", async (row, key) => {
    page = await renderPage({ path: "/settings/theme" });
    const menu = await openThemeMenu(page, row);
    expect([...menu.querySelectorAll("[role=menuitem]")].map((button) => button.textContent)).toEqual([
      "Copy Setting Key",
      "Reset to Default",
    ]);
    await click(item(menu, "Copy Setting Key")!);
    expect(page.provider.clipboard).toBe(key);
  });
});

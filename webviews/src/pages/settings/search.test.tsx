import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";
import { configureKeyStyle } from "../../ui/keyStyle";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, fire, ops, renderPage, rowElement, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  configureKeyStyle({});
  page?.unmount();
  page = null;
});

const search = (page: Rendered) => page.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
const resultKeys = (page: Rendered) =>
  [...page.container.querySelectorAll("[data-search-results] [data-row-key]:not([data-filtered])")].map((row) =>
    row.getAttribute("data-row-key"),
  );

test("opening the page focuses the search field", async () => {
  page = await renderPage();
  expect(document.activeElement).toBe(search(page));
});

test("search finds rows by keyword across sections, highlighted and editable", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(search(page), "transparency");
  expect(resultKeys(page)).toEqual(
    expect.arrayContaining(["appearance.backgroundOpacity", "appearance.backgroundBlur"]),
  );
  await changeValue(search(page), "font");
  const keys = resultKeys(page);
  expect(keys).toContain("terminal.fontFamily");
  expect(keys).toContain("appearance.metrics.chromeFontSize");
  expect(page.container.querySelector("[data-search-results] mark")?.textContent?.toLowerCase()).toBe("font");
  expect(
    page.container.querySelector('[data-search-results] [data-row-key="terminal.fontSize"] input.number'),
  ).not.toBeNull();
});

test("search finds Keep Mac Awake under the words people use for it", async () => {
  page = await renderPage();
  for (const query of ["keep awake", "sleep", "prevent sleep", "caffeinate", "stay awake"]) {
    await changeValue(search(page), query);
    expect(resultKeys(page)).toContain("sessions.keepAwake");
  }
});

test("search finds rows by current value", async () => {
  page = await renderPage({
    mock: { values: { "browser.newTabPage": "https://start.cmux.dev", "appearance.backgroundBlur": "glass-clear" } },
  });
  await changeValue(search(page), "start.cmux");
  expect(resultKeys(page)).toEqual(["browser.newTabPage"]);
  await changeValue(search(page), "clear glass");
  expect(resultKeys(page)).toContain("appearance.backgroundBlur");
  await changeValue(search(page), "zzzz-no-match");
  expect(page.container.querySelector(".empty[data-open]")).not.toBeNull();
});

test("Return reveals the row in its section and focuses its control; Esc clears, then focuses the list", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(search(page), "appearance.backgroundOpacity");
  await fire(search(page), "keydown", { key: "Enter" });
  // Appearance draws the background rows: Return opens it on the row.
  expect(page.history.location.pathname).toBe("/settings/appearance");
  expect(page.history.location.search).toBe("?focus=appearance.backgroundOpacity");
  expect(search(page).value).toBe("");
  expect(page.container.querySelector('[data-section="appearance"]')).not.toBeNull();
  const focused = document.activeElement as HTMLElement;
  expect(focused.closest("[data-row-key]")?.getAttribute("data-row-key")).toBe("appearance.backgroundOpacity");

  await changeValue(search(page), "abc");
  await fire(search(page), "keydown", { key: "Escape" });
  expect(search(page).value).toBe("");
  await fire(search(page), "keydown", { key: "Escape" });
  expect(document.activeElement?.getAttribute("data-section-link")).toBe("appearance");
});

test("Up/Down move between rows, Space toggles; dispatcher commands reset, go back and find; chords do nothing", async () => {
  page = await renderPage({ path: "/settings/privacy" });
  const sectionRows = [
    ...page.container.querySelectorAll<HTMLElement>(".content [data-row-key], .content [data-action-row]"),
  ];
  await fire(search(page), "keydown", { key: "ArrowDown" });
  expect(document.activeElement).toBe(sectionRows[0]!);
  // A toggle row by key, so a new row in Privacy and Security does not change what this test drives.
  const first = rowElement(page.container, "history.terminalCommands");
  first.focus();
  await fire(first, "keydown", { key: " " });
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "history.terminalCommands", value: true }]);
  // The page handles no Cmd chords: the app's key dispatcher owns them.
  await fire(first, "keydown", { key: "Backspace", metaKey: true });
  expect(ops(page.provider, "cmux.settings.reset")).toEqual([]);
  await run(() => page!.provider.sendCommand("reset"));
  expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key: "history.terminalCommands" }]);
  // The next row in the section's rendered order (the schema decides which one it is).
  const rows = [...page.container.querySelectorAll(".content [data-row-key], .content [data-action-row]")];
  const next = rows[rows.indexOf(first) + 1]!;
  await fire(first, "keydown", { key: "ArrowDown" });
  expect(document.activeElement).toBe(next);

  // A section entry is a router link: a click is a mouse click (WebKit sends one for Enter too).
  await click(page.container.querySelector('[data-section-link="browser"]')!);
  expect(page.history.location.pathname).toBe("/settings/browser");
  await fire(document.body, "keydown", { key: "[", metaKey: true });
  expect(page.history.location.pathname).toBe("/settings/browser");
  await run(() => page!.provider.sendCommand("back"));
  expect(page.history.location.pathname).toBe("/settings/privacy");
  await run(() => page!.provider.sendCommand("forward"));
  expect(page.history.location.pathname).toBe("/settings/browser");
  await fire(document.body, "keydown", { key: "f", metaKey: true });
  expect(document.activeElement).not.toBe(search(page));
  await run(() => page!.provider.sendCommand("find"));
  expect(document.activeElement).toBe(search(page));
});

test("Up/Down in search skip rows an earlier, wider query left mounted but filtered out", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(search(page), "font");
  await changeValue(search(page), "font family");
  const visible = resultKeys(page);
  expect(visible.length).toBeGreaterThan(0);
  expect(page.container.querySelector("[data-search-results] [data-filtered]")).not.toBeNull();
  await fire(search(page), "keydown", { key: "ArrowDown" });
  const first = document.activeElement as HTMLElement;
  expect(first.hasAttribute("data-filtered")).toBe(false);
  expect(first.getAttribute("data-row-key")).toBe(visible[0]!);
  // Walking down never lands on a filtered row, and the last visible row is the end of the list.
  for (let step = 0; step < visible.length + 2; step += 1) {
    await fire(document.activeElement!, "keydown", { key: "ArrowDown" });
    expect((document.activeElement as HTMLElement).hasAttribute("data-filtered")).toBe(false);
  }
  expect((document.activeElement as HTMLElement).getAttribute("data-row-key")).toBe(visible.at(-1)!);
});

test("a focused route reveals its row once values arrive and focuses its visible control", async () => {
  const revealed: string[] = [];
  const original = window.HTMLElement.prototype.scrollIntoView;
  window.HTMLElement.prototype.scrollIntoView = function (this: HTMLElement) {
    revealed.push(this.getAttribute("data-row-key") ?? this.tagName);
  };
  try {
    page = await renderPage({ path: "/settings/general?focus=app.quitBehavior" });
    expect(revealed).toEqual(["app.quitBehavior"]);
    const active = document.activeElement as HTMLElement;
    expect(active.closest('[data-row-key="app.quitBehavior"]')).not.toBeNull();
    expect(active.getAttribute("aria-hidden")).toBeNull();
  } finally {
    window.HTMLElement.prototype.scrollIntoView = original;
  }
});

// `app.keyStyle` is the page's own row (SettingsApp feeds it to the key layer): Vim's Esc in the
// search field gives the keyboard to the rows, j/k step them and G and gg reach the ends, / goes
// back; Emacs' Ctrl-N steps from the field. Standard keeps today's keys (Esc focuses the list).
// The row until settings-schema.json is regenerated with it, then the page's own value: both say the style.
function styledPage(style: string) {
  configureKeyStyle({ "app.keyStyle": style });
  return renderPage({ path: "/settings/privacy", mock: { values: { "app.keyStyle": style } } });
}

test("Vim and Emacs move through the rows as Up and Down do; Standard keeps today's keys", async () => {
  page = await styledPage("vim");
  const rows = [...page.container.querySelectorAll(".content [data-row-key], .content [data-action-row]")].filter(
    (row) => !row.matches("[data-filtered]") && !row.closest("[data-filtered], [inert]"),
  );
  await fire(search(page), "keydown", { key: "Escape", code: "Escape" });
  expect(document.activeElement).toBe(rows[0]!);
  await fire(document.activeElement!, "keydown", { key: "j", code: "KeyJ" });
  expect(document.activeElement).toBe(rows[1]!);
  await fire(document.activeElement!, "keydown", { key: "G", code: "KeyG", shiftKey: true });
  expect(document.activeElement).toBe(rows.at(-1)!);
  await fire(document.activeElement!, "keydown", { key: "g", code: "KeyG" });
  await fire(document.activeElement!, "keydown", { key: "g", code: "KeyG" });
  expect(document.activeElement).toBe(rows[0]!);
  await fire(document.activeElement!, "keydown", { key: "k", code: "KeyK" });
  expect(document.activeElement).toBe(search(page));
  await fire(rows[1]!, "keydown", { key: "/", code: "Slash" });
  expect(document.activeElement).toBe(search(page));
  page.unmount();

  page = await styledPage("emacs");
  await fire(search(page), "keydown", { key: "n", code: "KeyN", ctrlKey: true });
  const first = document.activeElement as HTMLElement;
  expect(first.matches("[data-row-key], [data-action-row]")).toBe(true);
  await fire(first, "keydown", { key: "n", code: "KeyN", ctrlKey: true });
  expect(document.activeElement).not.toBe(first);
  page.unmount();

  page = await styledPage("standard");
  const row = page.container.querySelector<HTMLElement>(".content [data-row-key]")!;
  row.focus();
  await fire(row, "keydown", { key: "j", code: "KeyJ" });
  expect(document.activeElement).toBe(row);
  await fire(search(page), "keydown", { key: "Escape", code: "Escape" });
  expect((document.activeElement as HTMLElement).getAttribute("data-section-link")).toBe("privacy");
});

// Leo, 2026-11-15: "I want people to not accidentally soft lock themselves and like have good
// recovery options". From Vim or Emacs, the Settings page gets back to Standard with keys alone:
// the search field still types (no letter is taken as a list key), Return opens the Key Style
// row on its menu button, and the menu picks Standard by keys.
for (const style of ["vim", "emacs"]) {
  test(`${style}: keys alone set Key Style back to Standard from the Settings search`, async () => {
    page = await styledPage(style);
    const field = search(page);
    for (const key of "key style") {
      const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
      field.dispatchEvent(event);
      expect(event.defaultPrevented).toBe(false);
    }
    await changeValue(field, "key style");
    expect(resultKeys(page)).toContain("app.keyStyle");
    await fire(field, "keydown", { key: "Enter" });
    const button = document.activeElement as HTMLElement;
    expect(button.closest("[data-row-key]")?.getAttribute("data-row-key")).toBe("app.keyStyle");
    // Return on a focused button: the browser sends the keydown, then a keyboard click (detail 0).
    const pressReturn = async (element: HTMLElement) => {
      await fire(element, "keydown", { key: "Enter" });
      await act(async () => {
        element.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, detail: 0 }));
      });
    };
    await pressReturn(button);
    const items = () => [...document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')];
    expect(items().length).toBe(3);
    const standard = items().find((item) => /standard/i.test(item.textContent ?? ""))!;
    // The menu's own keys (Home, then Return), which no key style changes.
    await fire(document.activeElement ?? button, "keydown", { key: "Home" });
    expect(document.activeElement === standard || standard.hasAttribute("data-highlighted")).toBe(true);
    await pressReturn(standard);
    expect(ops(page.provider, "cmux.settings.set")).toContainEqual({ key: "app.keyStyle", value: "standard" });
  });
}

test("search finds the Devices page by the words of its switches; a click opens it", async () => {
  page = await renderPage({ path: "/settings/general" });
  const hits = () =>
    [...page!.container.querySelectorAll("[data-search-results] [data-page-hit]")].map((hit) =>
      hit.getAttribute("data-page-hit"),
    );
  for (const query of ["devices", "control", "screen sharing", "mac screen", "remote control", "Devices"]) {
    await changeValue(search(page), query);
    expect(hits()).toContain("devices");
    expect(page.container.querySelector(".empty[data-open]")).toBeNull();
  }
  await changeValue(search(page), "zzzz-no-match");
  expect(hits()).toEqual([]);
  await changeValue(search(page), "screen sharing");
  await click(page.container.querySelector('[data-page-hit="devices"]')!);
  expect(page.history.location.pathname).toBe("/settings/devices");
  expect(search(page).value).toBe("");
  expect(page.container.querySelector('[data-section="devices"]')).not.toBeNull();
});

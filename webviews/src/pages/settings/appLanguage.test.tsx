// Settings > General > Language (`app.language`): the page switches language live when the host
// calls window.__cmuxSetAppLanguage (shared/appLanguage.ts), keeping its route; the picker offers
// System and every locale the page's string tables ship; and a Relaunch row shows under it only
// while the app's native menus (the language the app launched in) differ from the setting.
import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, ops, renderPage, rowElement, settle } = await import("./testing");
const { installAppLanguage, setAppLanguage } = await import("../shared/appLanguage");
installAppLanguage();
const { menusNeedRelaunch, shippedLanguages } = await import("./components/LanguageRelaunchRow");
const table = (await import("./generated/strings.json")).default as Record<string, Record<string, string>>;

let page: Rendered | null = null;
afterEach(async () => {
  await act(async () => setAppLanguage(null));
  page?.unmount();
  page = null;
});

async function switchTo(code: string | null): Promise<void> {
  await act(async () => {
    window.__cmuxSetAppLanguage?.(code);
    await Promise.resolve();
  });
  await settle();
}

test("the page switches language live: ja, then de, then System, on the same route", async () => {
  page = await renderPage();
  const container = page.container;
  const sidebarTitle = () => container.querySelector(".sidebar-title")?.textContent;
  const languageTitle = () => rowElement(container, "app.language").querySelector(".row-title")?.textContent;
  expect(sidebarTitle()).toBe(table.en["settingsPage.title"]);
  expect(languageTitle()).toBe(table.en["settings.app.language"]);

  await switchTo("ja");
  expect(sidebarTitle()).toBe(table.ja["settingsPage.title"]);
  expect(languageTitle()).toBe(table.ja["settings.app.language"]);
  expect(document.documentElement.lang).toBe("ja");

  await switchTo("de");
  expect(sidebarTitle()).toBe(table.de["settingsPage.title"]);
  expect(languageTitle()).toBe(table.de["settings.app.language"]);

  // System: the app's own languages (jsdom's en-US).
  await switchTo(null);
  expect(sidebarTitle()).toBe(table.en["settingsPage.title"]);
  expect(languageTitle()).toBe(table.en["settings.app.language"]);
  expect(page.history.location.pathname).toBe("/settings/general");
});

test("the picker offers System and every locale the page's string tables ship", async () => {
  page = await renderPage();
  const options = [...rowElement(page.container, "app.language").querySelectorAll("option")].map(
    (option) => option.value,
  );
  expect([...options].sort()).toEqual(["system", ...Object.keys(table)].sort());
  expect([...shippedLanguages()].sort()).toEqual(Object.keys(table).sort());
});

test("the menus need a relaunch only when the setting's language differs from the launch language", () => {
  const shipped = ["en", "de", "ja", "pt-BR", "zh-Hant"];
  expect(menusNeedRelaunch("system", ["en-US"], shipped)).toBe(false);
  expect(menusNeedRelaunch("en", ["en-US"], shipped)).toBe(false);
  expect(menusNeedRelaunch("ja", ["en-US"], shipped)).toBe(true);
  expect(menusNeedRelaunch("ja", ["ja-JP", "en"], shipped)).toBe(false);
  expect(menusNeedRelaunch("pt-BR", ["pt-PT"], shipped)).toBe(false);
  expect(menusNeedRelaunch("zh-Hant", ["zh-TW"], shipped)).toBe(false);
  expect(menusNeedRelaunch("de", ["zh-TW"], shipped)).toBe(true);
});

test("the Relaunch row shows under Language only while the menus' language differs, and relaunches", async () => {
  page = await renderPage();
  const relaunch = () => page!.container.querySelector<HTMLButtonElement>("[data-language-relaunch]");
  const select = rowElement(page.container, "app.language").querySelector("select")!;
  // jsdom launched in en-US.
  expect(relaunch()).toBeNull();

  await changeValue(select, "ja");
  expect(relaunch()).not.toBeNull();
  const row = relaunch()!.closest(".row")!;
  expect(row.querySelector(".row-title")?.textContent).toBe(table.en["settingsPage.language.relaunch.title"]);
  expect(relaunch()!.textContent).toBe(table.en["settingsPage.language.relaunch.button"]);
  // It sits right under the Language row, in its card.
  expect(row.previousElementSibling).toBe(rowElement(page.container, "app.language"));

  await click(relaunch()!);
  expect(ops(page.provider, "cmux.settings.language.relaunch")).toEqual([{}]);

  await changeValue(select, "en");
  expect(relaunch()).toBeNull();
  await changeValue(select, "system");
  expect(relaunch()).toBeNull();
});

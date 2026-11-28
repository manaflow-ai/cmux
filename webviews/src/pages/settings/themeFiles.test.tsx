// Save as Ghostty Theme and Import Theme File (cx-wqn5.1): the theme in the preview, with its edits,
// is saved as a Ghostty theme file and picked; a picked file is imported and picked; a name in use
// asks inline before replacing; a refusal shows inline.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, fire, ops, renderPage } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const files = (page: Rendered) => page.container.querySelector<HTMLElement>("[data-theme-files]")!;
const action = (page: Rendered, name: "save" | "import") =>
  files(page).querySelector<HTMLButtonElement>(`[data-theme-files-action="${name}"]`)!;
const previewed = (page: Rendered) =>
  page.container.querySelector("[data-theme-preview]")?.getAttribute("data-theme-preview");
const edited = { "appearance.theme": "Dracula", "appearance.themeEdits": { "Dracula/background": "#101010" } };

test("Save as Ghostty Theme saves the previewed theme with its edits and picks it", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: edited } });
  await click(action(page, "save"));
  const field = files(page).querySelector<HTMLInputElement>("input")!;
  expect(field.value).toBe("Dracula Custom");
  await changeValue(field, "Dracula Ink");
  await fire(files(page).querySelector("form")!, "submit");
  expect(ops(page.provider, "cmux.settings.theme.save")).toEqual([
    { name: "Dracula Ink", base: "Dracula", replace: false },
  ]);
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({ key: "appearance.theme", value: "Dracula Ink" });
  expect(previewed(page)).toBe("Dracula Ink");
  expect(page.provider.themeColors.find((theme) => theme.name === "Dracula Ink")?.background).toBe("#101010");
  expect(page.store.getSnapshot().domains.themes).toContain("Dracula Ink");
});

test("saving while following the system replaces only the side in view", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: { values: { "appearance.theme": "light:Apple System Colors Light,dark:Dracula" } },
  });
  const shown = previewed(page)!;
  await click(action(page, "save"));
  await changeValue(files(page).querySelector<HTMLInputElement>("input")!, "Mine");
  await fire(files(page).querySelector("form")!, "submit");
  const written = ops(page.provider, "cmux.settings.set").at(-1) as { value: string };
  expect(written.value).toMatch(/^light:.+,dark:.+$/);
  expect(written.value).toContain("Mine");
  expect(written.value.replace("Mine", shown)).toBe("light:Apple System Colors Light,dark:Dracula");
});

test("a name in use asks inline, and Replace saves over it", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: edited } });
  for (let round = 0; round < 2; round++) {
    await click(action(page, "save"));
    await changeValue(files(page).querySelector<HTMLInputElement>("input")!, "Dracula Custom");
    await fire(files(page).querySelector("form")!, "submit");
  }
  const prompt = files(page).querySelector<HTMLElement>('[data-theme-files-prompt="replace"]')!;
  expect(prompt.textContent).toContain("“Dracula Custom”");
  await click(prompt.querySelector(".danger")!);
  expect(ops(page.provider, "cmux.settings.theme.save").at(-1)).toEqual({
    name: "Dracula Custom",
    base: "Dracula Custom",
    replace: true,
  });
  expect(files(page).querySelector("[data-theme-files-prompt]")).toBeNull();
});

test("a refused name shows inline and writes nothing", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: edited } });
  await click(action(page, "save"));
  await changeValue(files(page).querySelector<HTMLInputElement>("input")!, "a/b");
  await fire(files(page).querySelector("form")!, "submit");
  expect(files(page).querySelector("[data-theme-files-error]")?.textContent).toContain("/ = #");
  expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
});

test("Import Theme File copies the picked file in and picks it; a name in use replaces only when asked", async () => {
  page = await renderPage({
    path: "/settings/theme",
    setup: (provider) => {
      const dracula = provider.themeColors.find((theme) => theme.name === "Dracula")!;
      provider.importable = { ...dracula, name: "Night Owl", background: "#011627" };
    },
  });
  await click(action(page, "import"));
  expect(ops(page.provider, "cmux.settings.theme.import")).toEqual([{}]);
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({ key: "appearance.theme", value: "Night Owl" });
  expect(previewed(page)).toBe("Night Owl");

  await click(action(page, "import"));
  const prompt = files(page).querySelector<HTMLElement>('[data-theme-files-prompt="replace"]')!;
  expect(prompt.textContent).toContain("“Night Owl”");
  await click(prompt.querySelector(".danger")!);
  expect(ops(page.provider, "cmux.settings.theme.import").at(-1)).toEqual({ token: "token-1", replace: true });
  expect(files(page).querySelector("[data-theme-files-prompt]")).toBeNull();

  // Leaving the picker writes nothing.
  page.provider.importable = null;
  const writes = ops(page.provider, "cmux.settings.set").length;
  await click(action(page, "import"));
  expect(ops(page.provider, "cmux.settings.set").length).toBe(writes);
});

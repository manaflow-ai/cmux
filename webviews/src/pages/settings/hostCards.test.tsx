// R82 commit 4: the Swift window's last cards are drawn by the page (the Theme section has its own
// test, themeStudio.test.tsx). The wallpaper grid
// writes appearance.background behind the experimental switch, Terminal shows the Ghostty facts,
// and Advanced shows the settings file and every problem of the last load.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const runs = (page: Awaited<ReturnType<typeof renderPage>>, op: string) =>
  page.provider.log.filter((entry) => entry.op === op).map((entry) => entry.params);

test("the wallpaper grid shows behind the experimental switch and writes appearance.background", async () => {
  const hidden = await renderPage({ path: "/settings/experimental" });
  expect(hidden.container.querySelector('[data-card="backdrop"]')).toBeNull();
  hidden.unmount();
  const page = await renderPage({
    path: "/settings/experimental",
    mock: { values: { "appearance.experimentalControls": true } },
  });
  const grid = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  expect(grid.querySelector("img")!.getAttribute("src")).toBe("backdrop/starryNight");
  await act(async () => grid.querySelector<HTMLButtonElement>('[aria-label="The Starry Night"]')!.click());
  await settle();
  expect(runs(page, "cmux.settings.set").at(-1)).toMatchObject({ key: "appearance.background", value: "starryNight" });
  page.unmount();
});

test("Terminal shows the Ghostty facts; Advanced shows the file and every problem", async () => {
  const terminal = await renderPage({ path: "/settings/terminal" });
  expect(terminal.container.textContent).toContain("~/.config/ghostty/config");
  terminal.unmount();
  const page = await renderPage({
    path: "/settings/advanced",
    mock: { diagnostics: [{ path: "nope.key", message: "unknown key" }] },
  });
  expect(page.container.textContent).toContain("/Users/me/.config/cmux/cmux-next.json");
  expect(page.container.querySelector("[data-problem]")!.textContent).toContain("unknown key");
  const reveal = [...page.container.querySelectorAll<HTMLButtonElement>("button")].find(
    (b) => b.textContent === "Show in Finder",
  )!;
  await act(async () => reveal.click());
  await settle();
  expect(runs(page, "cmux.settings.file.reveal").length).toBe(1);
  page.unmount();
});

test("Advanced names the loaded settings file and shows one Reload Configuration", async () => {
  const page = await renderPage({
    path: "/settings/advanced",
    mock: {
      settingsFile: "/Users/me/.config/cmux/cmux.json",
      diagnostics: [{ path: "nope.key", message: "unknown key" }],
    },
  });
  const text = page.container.textContent ?? "";
  expect(page.container.querySelector('[data-card="problems"] .group-title')!.textContent).toBe(
    "Problems in cmux.json",
  );
  const buttons = [...page.container.querySelectorAll<HTMLButtonElement>("button")].map((b) => b.textContent);
  expect(buttons.filter((title) => title === "Open cmux.json").length).toBe(1);
  expect(buttons.filter((title) => title === "Reload Configuration").length).toBe(1);
  expect(text).toContain("Every setting and shortcut in cmux.json goes back to its default.");
  expect(text).not.toContain("cmux-next.json");
  page.unmount();
});

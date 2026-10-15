// Settings > Appearance > Fonts (appearance.fonts.*): the group shows a live preview of a chat in the
// faces and size its rows pick, and redraws it as a row changes, before any chat is opened. Unset,
// the preview is today's chat: the system face at 14px and the chat's own monospaced code.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const preview = () => {
  const figure = page!.container.querySelector<HTMLElement>('[data-group="settings.group.fonts"] [data-font-preview]');
  if (!figure) throw new Error("the Fonts group shows no preview");
  return (name: string) => figure.style.getPropertyValue(name);
};

test("the Fonts group previews a chat in the chosen faces and size, live", async () => {
  page = await renderPage({ path: "/settings/appearance" });
  for (const key of ["appearance.fonts.ui", "appearance.fonts.code", "appearance.fonts.chatSize"]) {
    expect(page.container.querySelector(`[data-row-key="${key}"]`)).not.toBeNull();
  }
  expect(preview()("--font-preview-ui")).toContain("system-ui");
  expect(preview()("--font-preview-size")).toBe("14px");
  expect(preview()("--font-preview-code")).toStartWith("var(--cmux-font-code,");

  await run(() => page!.store.set("appearance.fonts.ui", "serif"));
  await run(() => page!.store.set("appearance.fonts.code", "JetBrains Mono"));
  await run(() => page!.store.set("appearance.fonts.chatSize", 17));
  expect(preview()("--font-preview-ui")).toStartWith("ui-serif");
  expect(preview()("--font-preview-code")).toStartWith('"JetBrains Mono",');
  expect(preview()("--font-preview-size")).toBe("17px");
});

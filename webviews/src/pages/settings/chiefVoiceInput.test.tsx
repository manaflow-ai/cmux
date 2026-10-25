// Settings > Chief > Voice input (Leo's list): the message box's mic is the Debug toggle
// home.voiceInput, so the row exists only where that tunable does (the host sends `voice_input`
// in DEV and NIGHTLY, null in Release). It reads and writes the tunable itself: on by default.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, ops } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="voice-input"]');
const toggle = (container: HTMLElement) => card(container)!.querySelector<HTMLButtonElement>('[role="switch"]')!;

test("a build without the tunable has no Voice input row", async () => {
  const page = await renderPage({
    path: "/settings/chief",
    setup: (provider) => provider.setHost({ ...provider.host, voice_input: null }),
  });
  await settle();
  expect(page.container.querySelector('[data-section="chief"]')).not.toBeNull();
  expect(card(page.container)).toBeNull();
  page.unmount();
});

test("the Voice input row shows home.voiceInput and its switch writes it", async () => {
  const page = await renderPage({
    path: "/settings/chief",
    setup: (provider) => provider.setHost({ ...provider.host, voice_input: { on: true } }),
  });
  await settle();
  expect(card(page.container)?.querySelector(".row-title")?.textContent).toBe("Voice input");
  expect(toggle(page.container).getAttribute("aria-checked")).toBe("true");
  await click(toggle(page.container));
  await settle();
  expect(ops(page.provider, "cmux.settings.voice_input.set")).toEqual([{ on: false }]);
  expect(toggle(page.container).getAttribute("aria-checked")).toBe("false");
  page.unmount();
});

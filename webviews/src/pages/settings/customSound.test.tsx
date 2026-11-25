// Notification sound rows (https://github.com/manaflow-ai/cmux/issues/55219): the menu ends with
// Custom Sound…, which asks the host for a file of the person's own; the host keeps a copy, lists
// it, and sets it as the row's sound, which ▷ then previews. Leaving the panel changes nothing. The
// Sound Duration row edits notifications.sounds.maxSeconds.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, rowElement } = await import("./testing");
const { CUSTOM_SOUND } = await import("./editors/SoundEditor");

const KEY = "notifications.sound";

async function pick(row: () => HTMLElement, value: string): Promise<void> {
  const select = row().querySelector<HTMLSelectElement>("select.ui-select-native")!;
  await act(async () => {
    select.value = value;
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await settle();
}

test("Custom Sound… imports a file through the host, sets it and previews it", async () => {
  const page = await renderPage({ path: "/settings/notifications" });
  const row = () => rowElement(page.container, KEY);
  const options = () => [...row().querySelectorAll<HTMLOptionElement>("select.ui-select-native option")];
  expect(options().at(-1)?.value).toBe(CUSTOM_SOUND);
  expect(options().at(-1)?.textContent).toBe("Custom Sound…");

  // The person leaves the panel: nothing is written and the row keeps its sound.
  page.provider.importableSound = null;
  await pick(row, CUSTOM_SOUND);
  expect(page.provider.log.filter((entry) => entry.op === "cmux.settings.sound.import").at(-1)!.params).toEqual({
    key: KEY,
  });
  expect(
    page.provider.log.some(
      (entry) => entry.op === "cmux.settings.set" && (entry.params as { key: string }).key === KEY,
    ),
  ).toBe(false);
  expect(row().querySelector<HTMLSelectElement>("select.ui-select-native")!.value).toBe("default");

  // The person picks a file: the host's copy becomes the row's sound and a menu item.
  page.provider.importableSound = "My Chime";
  await pick(row, CUSTOM_SOUND);
  expect(row().querySelector<HTMLSelectElement>("select.ui-select-native")!.value).toBe("My Chime");
  expect(options().map((option) => option.value)).toContain("My Chime");

  await act(async () => row().querySelector<HTMLButtonElement>('button[aria-label="Play Sound"]')!.click());
  expect(page.provider.log.filter((entry) => entry.op === "cmux.settings.sound.play").at(-1)!.params).toEqual({
    name: "My Chime",
  });
  page.unmount();
});

test("Sound Duration is an editable row for notifications.sounds.maxSeconds", async () => {
  const page = await renderPage({
    path: "/settings/notifications",
    mock: { values: { "notifications.sounds.maxSeconds": 2.5 } },
  });
  const row = rowElement(page.container, "notifications.sounds.maxSeconds");
  expect(row.textContent).toContain("Sound Duration");
  const field = row.querySelector<HTMLInputElement>("input")!;
  expect(Number(field.value)).toBe(2.5);
  page.unmount();
});

// A form holding typed values not saved yet tells the host (`cmux.settings.editing`), so the host
// keeps a hidden Settings tab's page instead of letting it go and losing them (Chrome's kUserEdits).
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, click } = await import("./testing");

type Page = Awaited<ReturnType<typeof renderPage>>;
const editing = (page: Page) =>
  page.provider.log.filter((entry) => entry.op === "cmux.settings.editing").map((entry) => entry.params);
const relays = (page: Page) =>
  page.container.querySelector<HTMLElement>('[data-card="devices"] [data-devices-group="relays"]')!;
const newRelay = (page: Page) => relays(page).querySelector<HTMLElement>('[data-relay-editor="new"]')!;

test("a relay form with typed values is unsaved until it saves", async () => {
  const page = await renderPage({ path: "/settings/devices" });
  await settle();
  await click(relays(page).querySelector('[data-devices-action="addRelay"]')!);
  expect(editing(page)).toEqual([]);
  await changeValue(newRelay(page).querySelector<HTMLInputElement>('[data-relay-field="name"]')!, "Home TURN");
  expect(editing(page)).toEqual([{ form: "relay:new", editing: true }]);
  await changeValue(
    newRelay(page).querySelector<HTMLTextAreaElement>('[data-relay-field="urls"]') as unknown as HTMLInputElement,
    "turn:a.example:3478",
  );
  await changeValue(newRelay(page).querySelector<HTMLInputElement>('[data-relay-field="secret"]')!, "s3cret-value");
  // Still the same unsaved form: no second report while it stays unsaved.
  expect(editing(page)).toEqual([{ form: "relay:new", editing: true }]);
  await click(newRelay(page).querySelector('[data-relay-action="save"]')!);
  expect(editing(page).at(-1)).toEqual({ form: "relay:new", editing: false });
  page.unmount();
});

test("a custom density edited and not saved is unsaved until Save", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  await settle();
  const card = () => page.container.querySelector<HTMLElement>('[data-card="density"]')!;
  await click(card().querySelector('[data-density-action="duplicate"]')!);
  await settle();
  // The copy is written as it is made: unsaved only until its write lands.
  expect(editing(page).at(-1) ?? { form: "density", editing: false }).toEqual({ form: "density", editing: false });
  const before = editing(page).length;
  await changeValue(card().querySelector<HTMLInputElement>('input[name="density-name"]')!, "Roomy");
  expect(editing(page).slice(before)).toEqual([{ form: "density", editing: true }]);
  await click(card().querySelector('[data-density-action="save"]')!);
  await settle();
  expect(editing(page).at(-1)).toEqual({ form: "density", editing: false });
  page.unmount();
});

test("an unsaved form that unmounts says it is no longer unsaved", async () => {
  const page = await renderPage({ path: "/settings/devices" });
  await settle();
  await click(relays(page).querySelector('[data-devices-action="addRelay"]')!);
  await changeValue(newRelay(page).querySelector<HTMLInputElement>('[data-relay-field="name"]')!, "Draft");
  expect(editing(page)).toEqual([{ form: "relay:new", editing: true }]);
  await click(newRelay(page).querySelector('[data-relay-action="cancel"]')!);
  expect(editing(page).at(-1)).toEqual({ form: "relay:new", editing: false });
  page.unmount();
});

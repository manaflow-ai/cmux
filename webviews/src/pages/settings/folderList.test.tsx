// picker.pinned and files.roots (folder_list rows): the page lists the folders with move up, move
// down and remove; Add Folder… asks the host (the cmux picker), which writes the chosen folders.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, rowElement } = await import("./testing");

test("a folder list adds through the host picker, reorders and removes", async () => {
  const page = await renderPage({ path: "/settings/general", mock: { values: { "picker.pinned": ["/a", "~/b"] } } });
  const row = () => rowElement(page.container, "picker.pinned");
  expect([...row().querySelectorAll("[data-folder]")].map((item) => item.getAttribute("data-folder"))).toEqual([
    "/a",
    "~/b",
  ]);
  await act(async () => row().querySelector<HTMLButtonElement>("[data-add-folder]")!.click());
  await settle();
  expect(page.provider.log.some((entry) => entry.op === "cmux.settings.folders.add")).toBe(true);
  expect([...row().querySelectorAll("[data-folder]")].map((item) => item.getAttribute("data-folder"))).toEqual([
    "/a",
    "~/b",
    "~/src",
  ]);
  const down = row().querySelector<HTMLButtonElement>('[data-folder="/a"] button[aria-label^="Move Down"]')!;
  await act(async () => down.click());
  await settle();
  const sets = page.provider.log.filter((entry) => entry.op === "cmux.settings.set");
  expect(sets.at(-1)!.params).toMatchObject({ key: "picker.pinned", value: ["~/b", "/a", "~/src"] });
  const remove = row().querySelector<HTMLButtonElement>('[data-folder="~/src"] button[aria-label^="Remove"]')!;
  await act(async () => remove.click());
  await settle();
  expect(page.provider.log.filter((entry) => entry.op === "cmux.settings.set").at(-1)!.params).toMatchObject({
    value: ["~/b", "/a"],
  });
  page.unmount();
});

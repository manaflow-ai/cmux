// The background picker's happy path (Leo, 2026-10-20): one background for the whole app, or a
// rotating one like macOS's. The first tiles are None, Shuffle Paintings, Shuffle Your Images and
// Shuffle a Folder…; This Workspace comes after them, secondary.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const runs = (page: Awaited<ReturnType<typeof renderPage>>, op: string) =>
  page.provider.log.filter((entry) => entry.op === op).map((entry) => entry.params);

const FOLDER = "/Users/me/Library/Application Support/cmux/Backgrounds";

async function picker(path = "/settings/appearance", background = "none") {
  const page = await renderPage({
    path,
    mock: {
      values: { "appearance.background": background },
      workspaceBackgrounds: [{ workspace: "ws-1", title: "Research", value: null }],
    },
  });
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      backdrops: [
        ...(page.provider.host.backdrops ?? []),
        {
          id: `file:${FOLDER}/Harbor.png`,
          title: "Harbor",
          attribution: "",
          collection: "yours",
          collection_title: "Your images",
        },
      ],
    }),
  );
  await settle();
  return { page, card: page.container.querySelector<HTMLElement>('[data-card="backdrop"]')! };
}

test("the first tiles are None and the shuffles", async () => {
  const { page, card } = await picker();
  const first = card.querySelector<HTMLElement>(".backdrop-grid")!;
  const labels = [...first.querySelectorAll<HTMLButtonElement>(":scope > button")].map(
    (tile) => tile.getAttribute("aria-label") ?? tile.querySelector(".backdrop-title")?.textContent,
  );
  expect(labels.slice(0, 4)).toEqual(["No wallpaper", "Shuffle Paintings", "Shuffle Your Images", "Shuffle a Folder…"]);
  page.unmount();
});

test("Shuffle Your Images shuffles the folder the person's images are in", async () => {
  const { page, card } = await picker();
  await act(async () => card.querySelector<HTMLInputElement>('[aria-label="Shuffle Your Images"]')!.click());
  await settle();
  expect(runs(page, "cmux.settings.set").at(-1)).toMatchObject({
    key: "appearance.background",
    value: `folder:${FOLDER}`,
  });
  page.unmount();
});

test("Shuffle a Folder… asks the app for a folder", async () => {
  const { page, card } = await picker();
  const button = [...card.querySelectorAll<HTMLButtonElement>("button")].find((tile) =>
    tile.textContent?.includes("Shuffle a Folder…"),
  )!;
  await act(async () => button.click());
  await settle();
  expect(runs(page, "cmux.settings.backdrop.image.folder").length).toBe(1);
  page.unmount();
});

test("a shuffled folder shows as the chosen tile, by the folder's name", async () => {
  const { page, card } = await picker("/settings/appearance", "folder:/Users/me/Pictures/Trips");
  const chosen = card.querySelector<HTMLInputElement>('button[aria-pressed="true"]')!;
  expect(chosen.textContent).toContain("Trips");
  page.unmount();
});

test("This Workspace comes after the shuffles: All Workspaces is the default", async () => {
  const { page, card } = await picker("/settings/appearance?focus=appearance.background&workspace=ws-1");
  const first = card.querySelector<HTMLElement>(".backdrop-grid")!;
  const scope = card.querySelector<HTMLElement>(".backdrop-scope")!;
  expect(first.compareDocumentPosition(scope) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  expect(card.querySelector<HTMLInputElement>('[aria-label="All Workspaces"]')!.checked).toBe(true);
  page.unmount();
});

test("Change Picture is in the card, on while a shuffle is chosen and off otherwise", async () => {
  const control = (card: HTMLElement) =>
    card
      .querySelector<HTMLElement>('[data-row-key="appearance.backgroundRotation"]')!
      .querySelector<HTMLInputElement>(".row-control input, .row-control button, .row-control select")!;
  const still = await picker();
  expect(control(still.card).disabled).toBe(true);
  still.page.unmount();
  const shuffling = await picker("/settings/appearance", "daily");
  expect(control(shuffling.card).disabled).toBe(false);
  shuffling.page.unmount();
});

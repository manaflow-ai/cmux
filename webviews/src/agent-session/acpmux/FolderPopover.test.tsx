import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";
import { importWithDom } from "../../../test/support/importWithDom";

const { FolderPopover } = await importWithDom(() => import("./FolderPopover"));
let root: Root | undefined;
let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
let saved: [string, boolean, unknown][] = [];

afterEach(async () => {
  if (root) await act(async () => root?.unmount());
  await teardownDom(saved, { window: dom?.window, scope });
  root = undefined;
  dom = undefined;
  saved = [];
});

async function openPicker(
  top: number,
  folders: { id: string; label: string; repo?: { root: string; top?: string; name: string; branch?: string } }[] = [
    { id: "/projects/cmux", label: "cmux" },
  ],
) {
  dom = new JSDOM("<!doctype html><main></main>", { url: "http://localhost/", pretendToBeVisual: true });
  const { window } = dom;
  const globals = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    DOMRect: window.DOMRect,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    localStorage: window.localStorage,
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]]);
  Object.assign(scope, globals);
  const mount = window.document.querySelector("main")!;
  root = createRoot(mount);
  await act(async () =>
    root?.render(
      <FolderPopover
        label="Project"
        menu="Location"
        face="Project"
        folders={folders}
        onPick={() => {}}
        onBrowse={() => {}}
      />,
    ),
  );
  mount.querySelector("span.acpmux-location-picker")!.getBoundingClientRect = () =>
    new window.DOMRect(100, top, 70, 20);
  const click = () => act(async () => mount.querySelector("button")!.click());
  await click();
  const popup = () => window.document.querySelector<HTMLElement>(".acpmux-folder-popover")!;
  return { window, click, popup };
}

test("expanding a repository's worktrees keeps the menu's width", async () => {
  const root = "/projects/cmux";
  const lane = `${root}/worktrees/a-very-long-worktree-name-for-the-width`;
  const { window, popup } = await openPicker(660, [
    { id: root, label: "cmux", repo: { root, top: root, name: "cmux", branch: "main" } },
    {
      id: lane,
      label: "lane",
      repo: { root, top: lane, name: "cmux", branch: "a-very-long-worktree-name-for-the-width" },
    },
    // Same-length names: which of them the estimate keeps must not change when the repository opens.
    ...["one", "two", "six", "ten", "pen", "hen", "den"].map((name) => ({
      id: `${root}/worktrees/${name}`,
      label: name,
      repo: { root, top: `${root}/worktrees/${name}`, name: "cmux", branch: name },
    })),
  ]);
  const measured = () =>
    [...popup().querySelectorAll<HTMLElement>(".acpmux-folder-fit > span")].map((line) => line.dataset.text);
  const closed = measured();
  expect(closed.some((text) => text?.includes("a-very-long-worktree-name"))).toBe(true);
  const disclosure = popup().querySelector<HTMLElement>(".acpmux-location-worktrees")!;
  await act(async () => disclosure.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
  expect(popup().querySelector("[data-worktree]")).not.toBeNull();
  expect(measured()).toEqual(closed);
});

test("a worktree count click holds the menu's height until the pointer leaves", async () => {
  const root = "/projects/cmux";
  const lane = `${root}/worktrees/lane`;
  const { window, popup } = await openPicker(660, [
    { id: root, label: "cmux", repo: { root, top: root, name: "cmux", branch: "main" } },
    { id: lane, label: "lane", repo: { root, top: lane, name: "cmux", branch: "lane" } },
  ]);
  const held = () => popup().style.getPropertyValue("--acpmux-folder-held-height");
  popup().getBoundingClientRect = () => new window.DOMRect(100, 400, 300, 180);
  expect(held()).toBe("");
  const count = () => popup().querySelector<HTMLElement>(".acpmux-location-worktrees")!;
  await act(async () => count().dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
  expect(popup().querySelector("[data-worktree]")).not.toBeNull();
  expect(held()).toBe("180px");
  // Closing them again keeps the same height: the rows under the pointer do not move.
  popup().getBoundingClientRect = () => new window.DOMRect(100, 380, 300, 200);
  await act(async () => count().dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
  expect(popup().querySelector("[data-worktree]")).toBeNull();
  expect(held()).toBe("180px");
  await act(async () => popup().dispatchEvent(new window.MouseEvent("pointerleave")));
  expect(held()).toBe("");
});

// #55182 drew every folder row of this Mac with a plain folder, while the chip above it drew the
// project's own icon (ProjectBadge). A repository's row draws the same badge as the chip.
test("a folder row of this Mac draws the project's badge, as the chip does", async () => {
  const root = "/projects/cmux";
  const { popup } = await openPicker(660, [
    { id: root, label: "cmux", repo: { root, top: root, name: "cmux-workspace", branch: "main" } },
    { id: "/projects/site", label: "site" },
  ]);
  const rows = [...popup().querySelectorAll<HTMLElement>(".acpmux-location-row[title]")];
  expect(rows.map((row) => row.title)).toEqual([root, "/projects/site"]);
  for (const row of rows) {
    expect(row.querySelector(".acpmux-project-badge")).not.toBeNull();
    expect(row.querySelector('[data-icon="folder"]')).toBeNull();
  }
  expect(rows[0]!.querySelector(".acpmux-menu-label")?.textContent).toBe("cmux-workspace");
});

// The composer's folder browser for another machine (RemoteFolderBrowser.tsx): opening a folder asks
// for that folder only, Use picks the folder shown, a folder outside the machine's start folders
// does not open, and an older acpmux says to update it.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { RemoteFolderBrowser } from "./RemoteFolderBrowser";
import type { BrowseParams, BrowseReply } from "./folderBrowse";
import { translate } from "./i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const HOME = "/home/leo";
const tree: Record<string, BrowseReply["entries"]> = {
  "": [{ name: "Projects", path: `${HOME}/Projects`, kind: "dir" }],
  [`${HOME}/Projects`]: [
    { name: "cmux", path: `${HOME}/Projects/cmux`, kind: "dir" },
    { name: "etc-link", path: "/etc", kind: "symlink", target: "dir", outside: true },
  ],
};

async function mount(list: (params: BrowseParams) => Promise<BrowseReply>) {
  const picked: string[] = [];
  const backs: number[] = [];
  root = createRoot(installDom());
  await act(async () => {
    root!.render(
      <RemoteFolderBrowser
        machine="big-red"
        peer="big-red"
        list={list}
        onPick={(path) => picked.push(path)}
        onBack={() => backs.push(1)}
      />,
    );
  });
  return { picked, backs };
}

const fromTree = (asked: BrowseParams[]) => async (params: BrowseParams) => {
  asked.push(params);
  const path = params.path ?? null;
  return {
    path,
    parent: path ? path.split("/").slice(0, -1).join("/") : null,
    home: HOME,
    entries: tree[path ?? ""] ?? [],
    total: 0,
    offset: 0,
  };
};

const rows = () => [...document.querySelectorAll<HTMLButtonElement>(".acpmux-browse-row")];
const click = (el: Element) => act(async () => void (el as HTMLElement).click());

test("opens one folder at a time and picks the folder shown", async () => {
  const asked: BrowseParams[] = [];
  const { picked } = await mount(fromTree(asked));
  expect(rows().map((r) => r.textContent)).toEqual(["Projects"]);
  // The machine's top is not a folder a chat starts in.
  expect(document.querySelector<HTMLButtonElement>(".acpmux-browse-use")!.disabled).toBe(true);
  await click(rows()[0]!);
  expect(asked.map((a) => a.path)).toEqual([undefined, `${HOME}/Projects`]);
  expect(asked.every((a) => a.dirsOnly === true && a.peer === "big-red")).toBe(true);
  expect(rows().map((r) => r.textContent)).toEqual(["cmux", "etc-link"]);
  await click(document.querySelector(".acpmux-browse-use")!);
  expect(picked).toEqual([`${HOME}/Projects`]);
});

test("a link out of the machine's start folders is listed but never opened", async () => {
  const asked: BrowseParams[] = [];
  await mount(fromTree(asked));
  await click(rows()[0]!);
  const link = rows().find((r) => r.textContent === "etc-link")!;
  expect(link.getAttribute("aria-disabled")).toBe("true");
  await click(link);
  expect(asked.length).toBe(2);
});

test("Up at the machine's top goes back to the menu's list", async () => {
  const { backs } = await mount(fromTree([]));
  await click(document.querySelector(".acpmux-browse-up")!);
  expect(backs.length).toBe(1);
});

test("an acpmux without the browse method says to update it", async () => {
  await mount(() => Promise.reject({ code: -32601, message: "Method not found" }));
  expect(document.querySelector('[role="alert"]')!.textContent).toBe(
    translate("composer.browseUnsupported", { machine: "big-red" }),
  );
});

test("a truncated listing shows the quiet line", async () => {
  await mount(async () => ({
    path: HOME,
    parent: "/home",
    home: HOME,
    entries: [{ name: "a", path: `${HOME}/a`, kind: "dir" }],
    total: 1,
    offset: 0,
    truncated: { reason: "deadline", scanned: 900 },
  }));
  expect(document.querySelector(".acpmux-browse-note")!.textContent).toBe(translate("composer.browseTruncated"));
});

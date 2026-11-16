// l10n-allow-file: test fixture replies and paths, not shipped UI.
// Leo 2026-10-22, of a reply that linked chromium-base-see-through.png and then named
// chromium-fixed-see-through.png and chromium-fixed-opaque.png as plain text beside it: "can you
// just enable all these". A bare file name in a reply is the chip of that file in a folder the
// reply names, once the host finds it there; otherwise it stays as written.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const SHOTS = "/Users/you/shots/";
const REPLY = [
  `Screenshots (Air-Blue): [chromium-base-see-through.png](${SHOTS}chromium-base-see-through.png) (before) and`,
  "chromium-fixed-see-through.png / `chromium-fixed-opaque.png` (after).",
  "",
  "Built with Next.js; config.json and gone.png are not in that folder, and `notes.md` is a folder there.",
].join("\n");

async function renderReply(source: string, files: Record<string, { place: "root" | "outside"; folder: boolean }>) {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { resetLinkStore, seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const asked: string[] = [];
  resetLinkStore();
  seedLinkStore({ policy: { outsideRoots: "confirm" } });
  // The host answers only for files it has; every other path is missing.
  setChipHost(async (method, params) => {
    if (method !== "link.inspect") return undefined;
    const paths = (params.paths as string[]) ?? [];
    asked.push(...paths);
    return {
      paths: Object.fromEntries(paths.map((path) => [path, files[path] ?? { place: "missing", folder: false }])),
    };
  });
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  await act(async () => root.render(<Markdown>{source}</Markdown>));
  // Let the batched inspects answer and the chips that wait on them draw.
  for (let pass = 0; pass < 4; pass++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return {
    rootElement,
    asked,
    chips: () => [...rootElement.querySelectorAll<HTMLElement>("button.is-path")].map((chip) => chip.dataset.path),
    async done() {
      await act(async () => root.unmount());
      setChipHost(undefined);
      resetLinkStore();
    },
  };
}

test("bare file names beside a linked file are chips of the files in its folder", async () => {
  const view = await renderReply(REPLY, {
    [`${SHOTS}chromium-base-see-through.png`]: { place: "outside", folder: false },
    [`${SHOTS}chromium-fixed-see-through.png`]: { place: "outside", folder: false },
    [`${SHOTS}chromium-fixed-opaque.png`]: { place: "outside", folder: false },
    [`${SHOTS}notes.md`]: { place: "outside", folder: true },
  });
  try {
    expect(view.chips()).toEqual([
      `${SHOTS}chromium-base-see-through.png`,
      `${SHOTS}chromium-fixed-see-through.png`,
      `${SHOTS}chromium-fixed-opaque.png`,
    ]);
    const text = view.rootElement.textContent!;
    // Names the host did not find there, and a folder, stay as written.
    expect(text).toContain("Next.js");
    expect(text).toContain("config.json and gone.png");
    expect(view.rootElement.querySelector("code.cv-code")?.textContent).toBe("notes.md");
    // `Next.js` was asked about in the reply's folder, never anywhere else.
    expect(view.asked.filter((path) => !path.startsWith(SHOTS))).toEqual([]);
  } finally {
    await view.done();
  }
});

test("a reply that names no folder asks nothing about its bare file names", async () => {
  const view = await renderReply("Wrote report.html and `summary.png`.", {});
  try {
    expect(view.chips()).toEqual([]);
    expect(view.asked).toEqual([]);
    expect(view.rootElement.textContent).toContain("Wrote report.html and summary.png.");
  } finally {
    await view.done();
  }
});

test("a bare name is looked up in the next folder the reply names when the first lacks it", async () => {
  const view = await renderReply("See `/tmp/a/log.txt` and `/tmp/b/trace.json`; the picture is shot.png.", {
    "/tmp/a/log.txt": { place: "outside", folder: false },
    "/tmp/b/trace.json": { place: "outside", folder: false },
    "/tmp/b/shot.png": { place: "outside", folder: false },
  });
  try {
    expect(view.chips()).toEqual(["/tmp/a/log.txt", "/tmp/b/trace.json", "/tmp/b/shot.png"]);
    expect(view.asked).toContain("/tmp/a/shot.png");
  } finally {
    await view.done();
  }
});

test("replyFolders and bareFileNames read the shapes an agent writes", async () => {
  const { bareFileNames, replyFolders, isBareFileName } =
    await import("../src/agent-session/acpmux/chips/replyFolders");
  expect(replyFolders("[a](/x/y/a.png) then `/x/z/` and ~/w/q.md, again /x/y/b.png")).toEqual([
    "/x/y/",
    "/x/z/",
    "~/w/",
  ]);
  expect(replyFolders("no paths here, a.png")).toEqual([]);
  expect(bareFileNames("a.png, b-c.PNG. version 4.5 and example.com, /x/d.png e.json:3").map((n) => n.name)).toEqual([
    "a.png",
    "b-c.PNG",
  ]);
  expect(isBareFileName("chromium-fixed-opaque.png")).toBe(true);
  expect(isBareFileName("ls a.png")).toBe(false);
});

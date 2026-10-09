import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
// The window's globals the pane and ui/Dialog (Base UI) read.
const NAMES = [
  "window",
  "document",
  "navigator",
  "location",
  "Element",
  "HTMLElement",
  "Node",
  "Event",
  "KeyboardEvent",
  "MouseEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = Object.fromEntries(NAMES.map((key) => [key, globals[key]]));
for (const name of NAMES) globals[name] = (dom.window as unknown as Record<string, unknown>)[name];
globals.window = dom.window;
globals.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
globals.IS_REACT_ACT_ENVIRONMENT = true;
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { chatGallery, galleryItems } = await import("./chatGallery");
const { ChatGallery } = await import("./ChatGallery");
const { SummaryPopover } = await import("./SummaryPopover");

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const png = (tag: string) => `data:image/png;base64,${tag}AAAA`;
const reply = (id: string, text: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "assistant", text });
const render = (id: string, input: unknown, extra: Partial<Tool> = {}): AcpmuxRow => ({
  id: `activity-${id}`,
  version: 1,
  at: 0,
  kind: "activity",
  items: [
    {
      kind: "tool",
      text: "",
      tool: {
        id,
        title: "mcp__cmux__render",
        kind: "other",
        status: "completed",
        inputSummary: JSON.stringify(input),
        ...extra,
      },
    },
  ],
});
const rows: AcpmuxRow[] = [
  reply("a", `First ![Light](${png("A")}).`),
  render("r1", { html: "<p>chart</p>", title: "Chart" }),
  render("r2", { html: "<p>failed</p>" }, { status: "failed" }),
  reply("b", `Again ![Light](${png("A")}) and ![Dark](${png("B")}).`),
  render("r3", { html: "<p>table</p>" }),
];

test("the gallery is the chat's images and render calls in transcript order, each image once", () => {
  expect(chatGallery(rows)).toEqual([
    { kind: "image", key: png("A"), src: png("A"), alt: "Light" },
    { kind: "render", key: "r1", call: { html: "<p>chart</p>", title: "Chart" } },
    { kind: "image", key: png("B"), src: png("B"), alt: "Dark" },
    { kind: "render", key: "r3", call: { html: "<p>table</p>" } },
  ]);
  expect(chatGallery([reply("x", "No pictures here.")])).toEqual([]);
});

test("a kind filter keeps only that kind; all keeps everything", () => {
  const items = chatGallery(rows);
  expect(galleryItems(items, "all")).toHaveLength(4);
  expect(galleryItems(items, "image").map((item) => item.key)).toEqual([png("A"), png("B")]);
  expect(galleryItems(items, "render").map((item) => item.key)).toEqual(["r1", "r3"]);
});

test("the gallery shows a tile per item, filters by kind and opens an image in the viewer", async () => {
  const opened: string[] = [];
  const container = document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(
      createElement(ChatGallery, {
        rows,
        onClose: () => undefined,
        onOpenImage: (src: string) => opened.push(src),
      }),
    ),
  );
  const dialog = () => document.querySelector(".acpmux-chat-gallery")!;
  const tiles = () => [...dialog().querySelectorAll("[data-gallery-kind]")].map((tile) => tile.getAttribute("data-gallery-kind"));
  expect(tiles()).toEqual(["image", "render", "image", "render"]);
  const filters = [...dialog().querySelectorAll<HTMLButtonElement>(".acpmux-chat-gallery-filter")];
  expect(filters.map((button) => button.textContent)).toEqual(["All 4", "Images 2", "Renders 2"]);

  await act(async () => filters[2]!.click());
  expect(tiles()).toEqual(["render", "render"]);
  expect(filters[2]!.getAttribute("aria-pressed")).toBe("true");

  await act(async () => filters[1]!.click());
  expect(tiles()).toEqual(["image", "image"]);
  await act(async () => dialog().querySelector<HTMLButtonElement>("[data-gallery-kind=image] button")!.click());
  expect(opened).toEqual([png("A")]);
  await act(async () => root.unmount());
});

test("the summary's Outputs section opens the gallery when the chat has images or renders", async () => {
  const summary = { scheduled: [], pullRequests: [], outputs: [], subagents: [], sources: [] };
  let galleries = 0;
  const container = document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(createElement(SummaryPopover, { summary, galleryCount: 3, onOpenGallery: () => galleries++ })),
  );
  const button = container.querySelector<HTMLButtonElement>(".acpmux-summary-gallery");
  expect(button?.textContent).toBe("Gallery 3");
  expect(button?.closest("section")?.getAttribute("aria-label")).toBe("Outputs");
  await act(async () => button!.click());
  expect(galleries).toBe(1);

  await act(async () => root.render(createElement(SummaryPopover, { summary, galleryCount: 0, onOpenGallery: () => galleries++ })));
  expect(container.querySelector(".acpmux-summary-gallery")).toBeNull();
  await act(async () => root.unmount());
});

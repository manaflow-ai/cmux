import { afterAll, afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { IconPack } from "./types";

const dom = new JSDOM(`<!doctype html><div id=root></div>`, {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => {
  Object.assign(globals, saved);
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Icon } = await import("./Icon");
const { IconsProvider } = await import("./IconsContext");
const { bundledIconPack } = await import("./iconPack");
const { rowIconSize, ICON_FLOOR, ROW_VIEWBOX } = await import("./iconSize");

let host: HTMLElement;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
});

type IconProps = Parameters<typeof Icon>[0];
async function render(props: IconProps, pack?: IconPack, accent?: "none" | "cat") {
  await act(async () =>
    root.render(
      <IconsProvider pack={pack} accent={accent}>
        <Icon {...props} />
      </IconsProvider>,
    ),
  );
  const svg = host.querySelector("svg");
  expect(svg).not.toBeNull();
  return svg!;
}

describe("Icon", () => {
  test("every pack icon renders paths in every style", async () => {
    const names = Object.keys(bundledIconPack.icons);
    expect(names.length).toBeGreaterThan(0);
    for (const name of names) {
      for (const accent of ["none", "cat"] as const) {
        for (const selected of [false, true]) {
          const svg = await render({ name, selected }, bundledIconPack, accent);
          expect(svg.querySelectorAll("path").length).toBeGreaterThan(0);
        }
      }
    }
  });

  test("a clear layer masks only the layers drawn before it", async () => {
    const pack: IconPack = {
      id: "test",
      version: 1,
      grid: 24,
      icons: {
        punched: {
          line: [
            { d: "M1 1L2 2", op: "fill" },
            { d: "M3 3L4 4", op: "stroke", w: 1.5 },
            { d: "M5 5L6 6", op: "clearStroke", w: 2, cap: "butt" },
            { d: "M7 7L8 8", op: "stroke", w: 1.5, accent: true },
          ],
          solid: [],
        },
      },
    };
    const svg = await render({ name: "punched" }, pack);
    const masks = svg.querySelectorAll("mask");
    expect(masks.length).toBe(1);
    const mask = masks[0];
    expect(mask.querySelector("rect")?.getAttribute("fill")).toBe("white");
    const clear = mask.querySelector("path")!;
    expect(clear.getAttribute("d")).toBe("M5 5L6 6");
    expect(clear.getAttribute("stroke")).toBe("black");
    expect(clear.getAttribute("stroke-linecap")).toBe("butt");
    const group = svg.querySelector(`g[mask="url(#${mask.id})"]`)!;
    expect(group).not.toBeNull();
    expect([...group.querySelectorAll("path")].map((path) => path.getAttribute("d"))).toEqual(["M1 1L2 2", "M3 3L4 4"]);
    const after = svg.querySelector('path[d="M7 7L8 8"]')!;
    expect(after.closest("g")).toBeNull();
    expect(after.getAttribute("stroke")).toBe("var(--agent-accent, currentColor)");
  });

  test("data-icon names the requested icon, even when it falls back", async () => {
    expect((await render({ name: "search" })).getAttribute("data-icon")).toBe("search");
    const warn = spyOn(console, "warn").mockImplementation(() => {});
    try {
      expect((await render({ name: "data.icon.missing" })).getAttribute("data-icon")).toBe("data.icon.missing");
    } finally {
      warn.mockRestore();
    }
  });

  test("an unknown name falls back to icon.missing and warns once", async () => {
    const warn = spyOn(console, "warn").mockImplementation(() => {});
    try {
      const svg = await render({ name: "no.such.icon" });
      const missing = bundledIconPack.icons["icon.missing"].line.map((layer) => layer.d);
      expect([...svg.querySelectorAll("path")].map((path) => path.getAttribute("d"))).toEqual(
        expect.arrayContaining(missing),
      );
      await render({ name: "no.such.icon", selected: true });
      expect(warn).toHaveBeenCalledTimes(1);
    } finally {
      warn.mockRestore();
    }
  });

  test("without icon.missing an unknown name draws a dashed square", async () => {
    const warn = spyOn(console, "warn").mockImplementation(() => {});
    try {
      const pack: IconPack = { id: "empty", version: 1, grid: 24, icons: {} };
      const svg = await render({ name: "also.missing" }, pack);
      expect(svg.querySelector("path")?.getAttribute("stroke-dasharray")).toBeTruthy();
    } finally {
      warn.mockRestore();
    }
  });

  test("size clamps to the floor, row crops the grid, title makes it an image", async () => {
    let svg = await render({ name: "account", size: 8 });
    expect(svg.getAttribute("width")).toBe(String(ICON_FLOOR));
    expect(svg.getAttribute("height")).toBe(String(ICON_FLOOR));
    expect(svg.getAttribute("viewBox")).toBe("0 0 24 24");
    expect(svg.getAttribute("aria-hidden")).toBe("true");

    svg = await render({ name: "account", size: 16, row: true, title: "Account" });
    expect(svg.getAttribute("width")).toBe("16");
    expect(svg.getAttribute("viewBox")).toBe(ROW_VIEWBOX);
    expect(svg.getAttribute("overflow")).toBe("visible");
    expect(svg.getAttribute("aria-hidden")).toBeNull();
    expect(svg.querySelector("title")?.textContent).toBe("Account");
  });
});

describe("rowIconSize", () => {
  test("scales the label by 1.2 with a 12px floor", () => {
    expect(rowIconSize(13)).toBe(16);
    expect(rowIconSize(11)).toBe(13);
    expect(rowIconSize(8)).toBe(12);
  });
});

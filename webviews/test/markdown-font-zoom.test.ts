// The markdown viewer's text size (user 2026-10-18): Cmd-= / Cmd-- step one pixel within 8-40,
// Cmd-0 goes back to the `markdown.font.size` default (16 when unset), and a viewer at the default
// follows a new default. Also: an editable file opens editable, and a read-only one says why.
import { describe, expect, test } from "bun:test";
import {
  MarkdownFontZoom,
  isMarkdownZoomCommand,
  markdownDefaultFontSize,
  nextFontSize,
  type ZoomStorage,
} from "../src/pages/markdown/fontZoom";
import { MarkdownStore } from "../src/pages/markdown/store";
import type { PageClient } from "../src/pages/shared/pageClient";

function root() {
  const values = new Map<string, string>();
  return { style: { setProperty: (name: string, value: string) => void values.set(name, value) }, values };
}

function memory(): ZoomStorage & { map: Map<string, string> } {
  const map = new Map<string, string>();
  return {
    map,
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => void map.set(key, value),
    removeItem: (key) => void map.delete(key),
  };
}

describe("markdown default font size", () => {
  test("reads markdown.font.size, else 16, clamped to 8-40", () => {
    expect(markdownDefaultFontSize(undefined)).toBe(16);
    expect(markdownDefaultFontSize({ font: { size: 18 } })).toBe(18);
    expect(markdownDefaultFontSize({ font: { size: "20px" } })).toBe(20);
    expect(markdownDefaultFontSize({ font: { size: "1.2rem" } })).toBe(16);
    expect(markdownDefaultFontSize({ font: { size: 99 } })).toBe(40);
    expect(markdownDefaultFontSize({ font: { size: 2 } })).toBe(8);
  });
});

describe("markdown zoom keys", () => {
  test("only the three size commands", () => {
    expect(["zoomIn", "zoomOut", "zoomReset"].every(isMarkdownZoomCommand)).toBe(true);
    expect(isMarkdownZoomCommand("save")).toBe(false);
  });

  test("one pixel a step, within the range; reset is the default", () => {
    expect(nextFontSize(null, 16, "zoomIn")).toBe(17);
    expect(nextFontSize(17, 16, "zoomOut")).toBeNull();
    expect(nextFontSize(null, 16, "zoomOut")).toBe(15);
    expect(nextFontSize(40, 16, "zoomIn")).toBe(40);
    expect(nextFontSize(8, 16, "zoomOut")).toBe(8);
    expect(nextFontSize(30, 16, "zoomReset")).toBeNull();
  });

  test("the viewer scales its text by size over the default and keeps it across a reload", () => {
    const page = root();
    const storage = memory();
    const zoom = new MarkdownFontZoom(page, storage);
    zoom.setSettings({ font: { size: 20 } });
    expect(page.values.get("--cmux-md-zoom")).toBe("1");
    expect(zoom.run("zoomIn")).toBe(21);
    expect(zoom.run("zoomIn")).toBe(22);
    expect(page.values.get("--cmux-md-zoom")).toBe("1.1");
    const reloaded = new MarkdownFontZoom(root(), storage);
    reloaded.setSettings({ font: { size: 20 } });
    expect(reloaded.fontSize).toBe(22);
    expect(zoom.run("zoomReset")).toBe(20);
    expect(page.values.get("--cmux-md-zoom")).toBe("1");
    expect(storage.map.size).toBe(0);
  });

  test("a viewer at the default follows a new default; a zoomed one keeps its size", () => {
    const atDefault = new MarkdownFontZoom(root(), memory());
    atDefault.setSettings({});
    atDefault.setSettings({ font: { size: 18 } });
    expect(atDefault.fontSize).toBe(18);
    const zoomed = new MarkdownFontZoom(root(), memory());
    zoomed.setSettings({});
    zoomed.run("zoomIn");
    zoomed.setSettings({ font: { size: 14 } });
    expect(zoomed.fontSize).toBe(17);
  });
});

describe("markdown read only", () => {
  function client(config: Record<string, unknown>): PageClient {
    return {
      call: async <R>(op: string) => (op === "cmux.markdown.config" ? config : {}) as R,
      subscribe: async () => () => {},
      handle: () => () => {},
    };
  }
  const file = { path: "/Users/someone/notes.md", text: "# Notes\n", hash: "abc" };

  test("a file the host opens writable is editable", async () => {
    const store = new MarkdownStore(client(file));
    await store.start();
    expect(store.getState().readOnly).toBe(false);
    expect(store.getState().readOnlyReason).toBeNull();
  });

  test("a read-only file names its reason", async () => {
    const store = new MarkdownStore(client({ ...file, readOnly: true, readOnlyReason: "permission" }));
    await store.start();
    expect(store.getState().readOnly).toBe(true);
    expect(store.getState().readOnlyReason).toBe("permission");
  });
});

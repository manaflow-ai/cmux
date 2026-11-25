// The diff viewer's text size (user 2026-11-19: "cmd + and - need to work in diff viewer"; "default font size needs
// to better match chat trajectory"). The app's key dispatcher sends `zoomIn`, `zoomOut` and `zoomReset` to the diff
// page (DiffPageCommand); each steps the code one pixel within 8-32, Cmd-0 goes back to the default, and the size
// survives a reload of the page. The default is the agent chat's code block size: 12 px on 20 px lines at the chat's
// text scale, never the old 10 px.
import { describe, expect, test } from "bun:test";
import { runDiffPageCommand } from "../src/diff/pageCommands";
import {
  DIFF_CODE_SIZE,
  DiffFontZoom,
  diffCodeLineHeight,
  diffDefaultCodeSize,
  type DiffZoomStorage,
} from "../src/diff-viewer/fontZoom";
import { resolveDiffViewerAppearance } from "../src/appearance";

function root() {
  const values = new Map<string, string>();
  return {
    style: {
      setProperty: (name: string, value: string) => void values.set(name, value),
      removeProperty: (name: string) => void values.delete(name),
    },
    values,
  };
}

function memory(): DiffZoomStorage & { map: Map<string, string> } {
  const map = new Map<string, string>();
  return {
    map,
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => void map.set(key, value),
    removeItem: (key) => void map.delete(key),
  };
}

describe("diff default code size", () => {
  test("is the chat's code block size: 12 px on 20 px lines at the chat's text scale", () => {
    expect(diffDefaultCodeSize(undefined, 1)).toBe(12);
    expect(diffCodeLineHeight(12)).toBe(20);
    expect(diffDefaultCodeSize(undefined, 1.25)).toBe(15);
    // A size the host sends (diff appearance) wins.
    expect(diffDefaultCodeSize(14, 1)).toBe(14);
  });

  test("the resolved appearance no longer draws code at 10 px", () => {
    expect(resolveDiffViewerAppearance(undefined).fontSize ?? 12).toBeGreaterThanOrEqual(12);
  });
});

describe("diff font zoom", () => {
  test("Cmd-= and Cmd-- step one pixel, Cmd-0 goes back to the default", () => {
    const target = root();
    const zoom = new DiffFontZoom(target, memory(), () => 1);
    expect(zoom.fontSize).toBe(12);
    expect(zoom.run("zoomIn")).toBe(13);
    expect(zoom.run("zoomIn")).toBe(14);
    expect(target.values.get("--cmux-diff-code-size")).toBe("14px");
    expect(target.values.get("--cmux-diff-code-line-height")).toBe(`${diffCodeLineHeight(14)}px`);
    expect(zoom.lineHeight).toBe(diffCodeLineHeight(14));
    expect(zoom.run("zoomOut")).toBe(13);
    expect(zoom.run("zoomReset")).toBe(12);
    expect(zoom.lineHeight).toBe(20);
  });

  test("stays within 8 to 32", () => {
    const zoom = new DiffFontZoom(root(), memory(), () => 1);
    for (let i = 0; i < 40; i++) zoom.run("zoomOut");
    expect(zoom.fontSize).toBe(DIFF_CODE_SIZE.min);
    for (let i = 0; i < 60; i++) zoom.run("zoomIn");
    expect(zoom.fontSize).toBe(DIFF_CODE_SIZE.max);
  });

  test("a reload of the page keeps the size, Cmd-0 forgets it", () => {
    const storage = memory();
    new DiffFontZoom(root(), storage, () => 1).run("zoomIn");
    expect(new DiffFontZoom(root(), storage, () => 1).fontSize).toBe(13);
    new DiffFontZoom(root(), storage, () => 1).run("zoomReset");
    expect(new DiffFontZoom(root(), storage, () => 1).fontSize).toBe(12);
  });

  test("tells its listeners the new line height, for the virtualizer's metrics", () => {
    const zoom = new DiffFontZoom(root(), memory(), () => 1);
    const heights: number[] = [];
    const stop = zoom.subscribe(() => heights.push(zoom.lineHeight));
    zoom.run("zoomIn");
    stop();
    zoom.run("zoomIn");
    expect(heights).toEqual([diffCodeLineHeight(13)]);
  });
});

describe("diff page zoom commands", () => {
  test("the host's zoom commands reach the viewer's zoom", () => {
    const ran: string[] = [];
    for (const command of ["zoomIn", "zoomOut", "zoomReset"]) {
      expect(runDiffPageCommand({ command }, (action) => (ran.push(action), true))).toBe(true);
    }
    expect(ran).toEqual(["diffViewerZoomIn", "diffViewerZoomOut", "diffViewerZoomReset"]);
  });
});

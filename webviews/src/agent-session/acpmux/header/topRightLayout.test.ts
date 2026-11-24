import { beforeEach, expect, test } from "bun:test";
import type { HeaderQuickTool } from "./headerQuickTools";
import { setHeaderState, headerState } from "./headerState";
import {
  dockSections,
  morphFace,
  notePaneOpened,
  readTopRightLayout,
  recentPanes,
  resetRecentPanes,
} from "./topRightLayout";

const tool = (id: HeaderQuickTool["id"], pressed = false): HeaderQuickTool => ({
  id,
  icon: id,
  label: id,
  pressed,
  run: () => undefined,
});

beforeEach(() => resetRecentPanes());

test("the App's layout is read; anything else keeps the page's", () => {
  expect(readTopRightLayout("morph")).toBe("morph");
  expect(readTopRightLayout("tabStrip")).toBe("tabStrip");
  expect(readTopRightLayout("pills")).toBeUndefined();
  expect(headerState().topRightLayout).toBe("row");
  setHeaderState({ topRightLayout: "dock", version: headerState().version + 1 });
  expect(headerState().topRightLayout).toBe("dock");
  setHeaderState({ topRightLayout: 3, version: headerState().version + 1 });
  expect(headerState().topRightLayout).toBe("dock");
  setHeaderState({ topRightLayout: "row", version: headerState().version + 1 });
});

test("a pick moves to the front of the recent panes, once", () => {
  notePaneOpened("terminal");
  notePaneOpened("browser");
  notePaneOpened("terminal");
  expect(recentPanes()).toEqual(["terminal", "browser"]);
});

test("the morph control wears the open pane picked last, else its own glyph", () => {
  const tools = [tool("changes", true), tool("terminal", true), tool("browser")];
  expect(morphFace([tool("terminal"), tool("browser")], [])).toBeUndefined();
  // Opened some other way: the header's order.
  expect(morphFace(tools, [])?.id).toBe("changes");
  expect(morphFace(tools, ["terminal", "changes"])?.id).toBe("terminal");
  // The pane picked last was closed since: the next open one.
  expect(morphFace(tools, ["browser", "terminal"])?.id).toBe("terminal");
});

test("the dock lists open panes, then recent closed ones, then the rest, each once", () => {
  const tools = [tool("changes"), tool("terminal", true), tool("browser"), tool("files")];
  const sections = dockSections(tools, ["browser", "terminal"]);
  expect(sections.open.map((t) => t.id)).toEqual(["terminal"]);
  expect(sections.recent.map((t) => t.id)).toEqual(["browser"]);
  expect(sections.more.map((t) => t.id)).toEqual(["changes", "files"]);
});

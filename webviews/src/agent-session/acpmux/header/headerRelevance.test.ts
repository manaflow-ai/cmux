import { expect, test } from "bun:test";
import type { HeaderQuickTool } from "./headerQuickTools";
import { headerRelevance, readHeaderIconsStyle, type HeaderRelevanceInput } from "./headerRelevance";

const tool = (id: HeaderQuickTool["id"]): HeaderQuickTool => ({ id, icon: id, label: id });
const row = [tool("changes"), tool("terminal"), tool("browser")];
const ids = (tools: readonly HeaderQuickTool[]) => tools.map((one) => one.id);
const split = (input: Partial<HeaderRelevanceInput>) =>
  headerRelevance({ style: "contextual", tools: row, lit: [], ...input });

test("standard keeps today's row and makes nothing dormant", () => {
  const { shown, dormant } = split({ style: "standard" });
  expect(ids(shown)).toEqual(["changes", "terminal", "browser"]);
  expect(dormant).toEqual([]);
});

test("a new chat shows no quick tools: Terminal and Browser wait", () => {
  const { shown, dormant } = split({ tools: [tool("terminal"), tool("browser")] });
  expect(shown).toEqual([]);
  expect(ids(dormant)).toEqual(["terminal", "browser"]);
});

test("Changes stays: it is only in the list while the chat has changes", () => {
  expect(ids(split({}).shown)).toEqual(["changes"]);
});

test("Terminal shows while its terminal is open, so the button can close it", () => {
  expect(ids(split({ lit: ["splitRight"] }).shown)).toEqual(["changes", "terminal"]);
});

test("Browser shows once the chat names a page, or while its browser or page is open", () => {
  expect(ids(split({ previewUrl: "http://localhost:3000/" }).shown)).toContain("browser");
  expect(ids(split({ lit: ["splitBrowserRight"] }).shown)).toContain("browser");
  expect(ids(split({ lit: ["preview"] }).shown)).toContain("browser");
});

test("buttons a person added stay", () => {
  const added = [tool("splitDown"), tool("files"), tool("newTab")];
  expect(ids(split({ tools: added }).shown)).toEqual(["splitDown", "files", "newTab"]);
});

test("peek splits the same way; only the drawing differs", () => {
  expect(split({ style: "contextualPeek" })).toEqual(split({}));
});

test("an unknown style on the wire keeps the current one", () => {
  expect(readHeaderIconsStyle("contextualPeek")).toBe("contextualPeek");
  expect(readHeaderIconsStyle("loud")).toBeUndefined();
  expect(readHeaderIconsStyle(undefined)).toBeUndefined();
});

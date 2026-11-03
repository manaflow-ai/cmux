import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { scrollActiveMenuRow } from "./scrollActiveMenuRow";

test("scrolls only the selected option inside its menu, including React ids with colons", () => {
  const dom = new JSDOM('<div id="menu"><div id=":r1:-21"></div></div><div id=":r1:-22"></div>');
  const menu = dom.window.document.getElementById("menu")!;
  const selected = dom.window.document.getElementById(":r1:-21")!;
  const outside = dom.window.document.getElementById(":r1:-22")!;
  const calls: ScrollIntoViewOptions[] = [];
  selected.scrollIntoView = (options) => calls.push(options as ScrollIntoViewOptions);
  outside.scrollIntoView = () => calls.push({ block: "end" });
  scrollActiveMenuRow(menu, selected.id);
  scrollActiveMenuRow(menu, outside.id);
  expect(calls).toEqual([{ block: "nearest" }]);
  dom.window.close();
});

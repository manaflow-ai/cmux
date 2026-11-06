import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createStripLabelsFit, fitCreateStrip } from "../src/agent-session/acpmux/newtab/createStripFit";

// The visual review at 495a9570 (French, 320px): all three create actions read "Nouv…". The strip goes
// icon-only together once any label no longer fits beside its glyph, measured per language.
function strip(itemWidth: number, titleWidths: number[]) {
  const dom = new JSDOM(`<!doctype html><style>
    .nt-create-strip-item { padding-left: 8px; padding-right: 8px; column-gap: 8px; }
  </style><div class="nt-create-strip"></div>`);
  const doc = dom.window.document;
  const root = doc.querySelector<HTMLElement>(".nt-create-strip")!;
  for (const width of titleWidths) {
    const item = doc.createElement("div");
    item.className = "nt-create-strip-item";
    item.innerHTML = '<span class="nt-row-glyph"></span><span class="nt-row-title">label</span>';
    Object.defineProperty(item, "clientWidth", { value: itemWidth });
    Object.defineProperty(item.querySelector(".nt-row-glyph")!, "offsetWidth", { value: 16 });
    Object.defineProperty(item.querySelector(".nt-row-title")!, "scrollWidth", { value: width });
    root.append(item);
  }
  return root;
}

test("labels that fit beside their glyphs keep showing", () => {
  // 120px items: 120 - 8 - 8 - 16 - 8 = 80px of room for each label.
  const root = strip(120, [72, 80, 60]);
  expect(createStripLabelsFit(root)).toBe(true);
  fitCreateStrip(root);
  expect(root.hasAttribute("data-icons-only")).toBe(false);
});

test("one label that does not fit turns all three into icons", () => {
  const root = strip(120, [72, 168, 60]);
  expect(createStripLabelsFit(root)).toBe(false);
  fitCreateStrip(root);
  expect(root.hasAttribute("data-icons-only")).toBe(true);
});

test("a strip with no width yet is not judged", () => {
  expect(createStripLabelsFit(strip(0, [300, 300, 300]))).toBe(true);
});

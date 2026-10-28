// The toolbar's layout button shows the chosen layout: two rows while unified, two columns while
// split, the frame cut on the diagonal while auto. Its tooltip names the next layout (auto, split,
// unified).
import { expect, test } from "bun:test";
import { toolbarPillButtons } from "../src/toolbar-model";

const layoutButton = (layout: "split" | "unified" | "auto") =>
  toolbarPillButtons({
    options: { collapsed: false, layout, wordWrap: false },
    filesVisible: true,
    optionsOpen: false,
    findOpen: false,
  }).find((button) => button.id === "layout")!;

test("each layout shows its own icon and offers the next layout", () => {
  expect(layoutButton("auto")).toMatchObject({ icon: "auto", labelKey: "switchToSplitDiff" });
  expect(layoutButton("split")).toMatchObject({ icon: "split", labelKey: "switchToUnifiedDiff" });
  expect(layoutButton("unified")).toMatchObject({ icon: "unified", labelKey: "switchToAutoLayout" });
});

test("the layout button is never unavailable: split stays split in a narrow pane", () => {
  for (const layout of ["unified", "split", "auto"] as const) {
    expect(layoutButton(layout).unavailable).toBeUndefined();
  }
});

// The toolbar's layout button shows the layout on screen: two columns while split, two rows while
// unified (and while split does not fit, which draws unified). Its tooltip names the other layout.
import { expect, test } from "bun:test";
import { toolbarPillButtons } from "../src/toolbar-model";

const layoutButton = (layout: "split" | "unified", splitFits?: boolean) =>
  toolbarPillButtons({
    options: { collapsed: false, layout, wordWrap: false },
    splitFits,
    filesVisible: true,
    optionsOpen: false,
    findOpen: false,
  }).find((button) => button.id === "layout")!;

test("split shows columns and offers unified; unified shows rows and offers split", () => {
  expect(layoutButton("split")).toMatchObject({ icon: "split", labelKey: "switchToUnifiedDiff" });
  expect(layoutButton("unified")).toMatchObject({ icon: "unified", labelKey: "switchToSplitDiff" });
});

test("a pane too narrow for split shows rows, as the diff it draws", () => {
  expect(layoutButton("split", false)).toMatchObject({ icon: "unified", unavailable: true });
});

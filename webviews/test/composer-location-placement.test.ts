import { expect, test } from "bun:test";
import { resolveUiSide } from "../src/ui/anchor";

const anchor = (top: number, bottom = top + 28) => ({ top, bottom });

test("project and environment menus prefer below when the full menu fits", () => {
  const side = resolveUiSide(anchor(120), 320, 720, { side: "below" });
  expect(side).toBe("below");
});

test("the shared placement rule flips above only when below has less room", () => {
  expect(resolveUiSide(anchor(620), 320, 720, { side: "below" })).toBe("above");
  expect(resolveUiSide(anchor(380), 320, 420, { side: "below" })).toBe("above");
});

test("a short pane still uses the side with usable room", () => {
  expect(resolveUiSide(anchor(180), 320, 220, { side: "below" })).toBe("above");
});

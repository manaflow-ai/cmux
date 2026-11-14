// Which side a composer location menu (folder, machine, branch) opens on (locationPopover.ts
// `locationMenuSide`). Away from the chat when the menu's shortest form fits there; else the other
// side, so the menu never covers its own control and a second press on it still closes the menu.
// The browser play `agent-pane.composer-context-away` checks the same rule on rendered menus.
import { expect, test } from "bun:test";
import { locationMenuSide } from "../src/agent-session/acpmux/locationPopover";

const VIEWPORT = 560;

/// A control at `top` (22 px tall) inside a composer box from `composerTop` to `composerBottom`,
/// or outside any composer when `composerTop` is undefined.
function control(top: number, composerTop?: number, composerBottom?: number): Element {
  const rect = (t: number, b: number) => ({ top: t, bottom: b }) as DOMRect;
  const composer =
    composerTop === undefined ? null : { getBoundingClientRect: () => rect(composerTop, composerBottom ?? VIEWPORT) };
  return {
    getBoundingClientRect: () => rect(top, top + 22),
    closest: () => composer,
  } as unknown as Element;
}

test("a new chat's composer at the window's foot opens its menus up, clear of the control", () => {
  // The case from dogfood: ~81 px under the control, far too short for the menu.
  expect(locationMenuSide(control(443, 443, 540), VIEWPORT)).toBe("top");
});

test("a composer in the lower half opens down, away from the chat, when the menu fits there", () => {
  expect(locationMenuSide(control(300, 300, 420), VIEWPORT)).toBe("bottom");
});

test("a composer high on the page (New Tab) opens up, away from the chats under it", () => {
  expect(locationMenuSide(control(255, 255, 360), 720)).toBe("top");
});

test("a composer high on the page with no room above opens down instead of covering its control", () => {
  expect(locationMenuSide(control(40, 40, 140), VIEWPORT)).toBe("bottom");
});

test("outside a composer the menu prefers below when the full menu fits", () => {
  expect(locationMenuSide(control(140), 900)).toBe("bottom");
  expect(locationMenuSide(control(700), 900)).toBe("top");
});

test("no control gives no side", () => {
  expect(locationMenuSide(null, VIEWPORT)).toBeUndefined();
});

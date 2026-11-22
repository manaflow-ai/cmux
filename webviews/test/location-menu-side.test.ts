// Which side a composer location menu (folder, machine, branch) opens on (locationPopover.ts
// `locationMenuSide`). Away from the composer's text field (Leo 2026-11-22: "the things should
// usually if possible open away from the text input") while the search field and a few rows fit
// there; with no field drawn, away from the chat when the menu's shortest form fits; else the other
// side, so the menu never covers its own control and a second press on it still closes the menu.
// The browser play `agent-pane.composer-context-away` checks the same rule on rendered menus.
import { expect, test } from "bun:test";
import {
  AWAY_FROM_INPUT_FLOOR,
  FOLDER_MENU_LIST_CAP,
  folderMenuShortest,
  locationMenuHeights,
  locationMenuSide,
} from "../src/agent-session/acpmux/locationPopover";

const VIEWPORT = 560;

/// A control at `top` (22 px tall) inside a composer box from `composerTop` to `composerBottom`,
/// or outside any composer when `composerTop` is undefined. `field`: the composer's text field
/// from its top to its bottom; none drawn when undefined.
function control(top: number, composerTop?: number, composerBottom?: number, field?: [number, number]): Element {
  const rect = (t: number, b: number) => ({ top: t, bottom: b, height: b - t }) as DOMRect;
  const drawn = field && { getBoundingClientRect: () => rect(field[0], field[1]) };
  const composer =
    composerTop === undefined
      ? null
      : {
          getBoundingClientRect: () => rect(composerTop, composerBottom ?? VIEWPORT),
          querySelector: () => drawn ?? null,
        };
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

test("the folder menu's taller list picks its side by its own height, the shared cap stays for the others", () => {
  // About 370 px below and 490 above: the shared menu (320) fits below, the folder menu (500) does not.
  expect(locationMenuSide(control(500), 900)).toBe("bottom");
  expect(locationMenuSide(control(500), 900, FOLDER_MENU_LIST_CAP)).toBe("top");
  expect(locationMenuHeights(1, FOLDER_MENU_LIST_CAP)).toEqual({ tallest: 500, shortest: 220 });
  expect(locationMenuHeights(1)).toEqual({ tallest: 320, shortest: 220 });
});

test("the folder menu's shortest size counts its actions and up to three of its folders", () => {
  // The search field, padding and rule (54), 30 a folder row, 28 an action.
  expect(folderMenuShortest(0, 3)).toBe(138);
  expect(folderMenuShortest(1, 5)).toBe(224);
  expect(folderMenuShortest(3, 6)).toBe(312);
  // Past three folders the list scrolls: no more room is asked for.
  expect(folderMenuShortest(4000, 6)).toBe(312);
  expect(locationMenuHeights(1.25, FOLDER_MENU_LIST_CAP, folderMenuShortest(3, 6)).shortest).toBe(390);
});

test("the folder menu leaves a side too short for its actions and folders when the other has more room", () => {
  // A composer in the lower half: about 264 px below its control and 586 above. The shared menu's
  // shortest form (220) fits below, away from the chat; a folder menu of six actions over three
  // folders (312) does not, so it opens up. One of three actions over one folder (168) fits below.
  expect(locationMenuSide(control(600, 600, 700), 900)).toBe("bottom");
  expect(locationMenuSide(control(600, 600, 700), 900, FOLDER_MENU_LIST_CAP, folderMenuShortest(3, 6))).toBe("top");
  expect(locationMenuSide(control(600, 600, 700), 900, FOLDER_MENU_LIST_CAP, folderMenuShortest(1, 3))).toBe("bottom");
  // Neither side fits it: the side with more room.
  expect(locationMenuSide(control(300, 300, 420), 560, FOLDER_MENU_LIST_CAP, folderMenuShortest(3, 6))).toBe("top");
});

test("a New Tab folder menu with a few rows still opens up, away from the chats under it", () => {
  // About 241 px over the control: one folder and five actions (224) fit there; three folders and
  // six actions (312) do not, and the 437 px under the control take the menu instead.
  expect(locationMenuSide(control(255, 255, 360), 720, FOLDER_MENU_LIST_CAP, folderMenuShortest(1, 5))).toBe("top");
  expect(locationMenuSide(control(255, 255, 360), 720, FOLDER_MENU_LIST_CAP, folderMenuShortest(3, 6))).toBe("bottom");
});

test("Lucas's New Tab composer under the window's middle opens the folder menu up, clear of the field", () => {
  // 900x700 gallery: the strip's control at 245-267, the field at 274-325, 233 px over the control.
  // Away from the chat said down, over the field and the "Bypass permissions" chip; the field says up,
  // even though the folder menu's whole shortest form (254) is a little taller than that room.
  const strip = control(245, 245, 360, [274, 325]);
  expect(locationMenuSide(strip, 700, FOLDER_MENU_LIST_CAP, folderMenuShortest(2, 5))).toBe("top");
});

test("a control under the field opens its menu down, away from the field, when there is room", () => {
  expect(locationMenuSide(control(340, 240, 360, [250, 320]), 900)).toBe("bottom");
});

test("away from the field the menu keeps a floor: short of it, the other side", () => {
  // The control 100 px under the window's top: 86 px over it, less than the floor (150).
  expect(AWAY_FROM_INPUT_FLOOR).toBe(150);
  expect(locationMenuSide(control(100, 100, 260, [130, 200]), 900)).toBe("bottom");
  // 160 px over it: the floor fits, so the menu stays up and its list scrolls.
  expect(
    locationMenuSide(control(174, 174, 330, [204, 270]), 900, FOLDER_MENU_LIST_CAP, folderMenuShortest(3, 6)),
  ).toBe("top");
});

test("a chat pane's strip over the field opens up, and a composer with no field drawn keeps the chat rule", () => {
  expect(locationMenuSide(control(300, 300, 420, [330, 400]), VIEWPORT)).toBe("top");
  expect(locationMenuSide(control(300, 300, 420), VIEWPORT)).toBe("bottom");
});

test("no control gives no side", () => {
  expect(locationMenuSide(null, VIEWPORT)).toBeUndefined();
});

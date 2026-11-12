// Floating UI follows Text Size (Leo, 2026-11-12: "evidently you zoom in and it doesn't really, you
// know, it doesn't follow, right?"). Text Size is not a page zoom: the App writes
// `--cmux-interface-scale` on <html> and dispatches `cmux-ui-scale-change`, and the type tokens grow
// with it. So a floating surface's JS geometry (the Base picker's clamp, the location menu's side
// pick, the tool preview's width) reads the scale where it places (ui/interfaceScale.ts) and places
// again on the event, and the floating surfaces' stylesheets frame them in `--ui-px`
// (ui/popupSurface.css), never a bare px. The second half is the detector for the class: a floating
// surface listed here that frames itself in px literals fails.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import {
  POPOVER_GAP,
  POPOVER_WIDTH,
  VIEWPORT_MARGIN,
  computePopoverStyle,
  popoverWidth,
} from "../src/branchBasePopover";
import { locationMenuHeights, locationMenuSide } from "../src/agent-session/acpmux/locationPopover";
import { INTERFACE_SCALE_EVENT, interfaceScale, onInterfaceScaleChange, scaledPx } from "../src/ui/interfaceScale";
import { tooltipScale } from "../src/ui/tooltipTokens";

let dom: JSDOM | undefined;
afterEach(() => {
  dom?.window.close();
  dom = undefined;
});

/** A page at `scale` (as DesignSettings.interfaceScaleScript writes it), `width` x `height`. */
function page(scale?: number, width = 1024, height = 768): Window {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true });
  const view = dom.window as unknown as Window;
  Object.defineProperty(view, "innerWidth", { value: width, configurable: true });
  Object.defineProperty(view, "innerHeight", { value: height, configurable: true });
  if (scale !== undefined) setScale(view, scale);
  return view;
}

function setScale(view: Window, scale: number): void {
  view.document.documentElement.style.setProperty("--cmux-interface-scale", String(scale));
  // The page's own Event: a JSDOM window takes only events of its own realm.
  const PageEvent = (view as unknown as typeof globalThis).Event;
  view.dispatchEvent(new PageEvent(INTERFACE_SCALE_EVENT));
}

const rect = (left: number, top: number, width = 80, height = 24) =>
  ({ left, top, right: left + width, bottom: top + height, width, height, x: left, y: top }) as DOMRect;

test("the scale reads the token the App writes, and 1 with none, a bad value or no window", () => {
  expect(interfaceScale(page(1.5))).toBe(1.5);
  expect(scaledPx(320, page(1.25))).toBe(400);
  expect(interfaceScale(page())).toBe(1);
  const bad = page();
  bad.document.documentElement.style.setProperty("--cmux-interface-scale", "nope");
  expect(interfaceScale(bad)).toBe(1);
  expect(interfaceScale(null)).toBe(1);
  // The tooltip reads the same value.
  expect(tooltipScale(page(1.5).document)).toBe(1.5);
});

test("a listener hears each scale change and reads the new scale; unsubscribed, it hears none", () => {
  const view = page(1);
  const heard: number[] = [];
  const stop = onInterfaceScaleChange(() => heard.push(interfaceScale(view)), view);
  setScale(view, 1.25);
  setScale(view, 1.5);
  stop();
  setScale(view, 1);
  expect(heard).toEqual([1.25, 1.5]);
});

test("the Base picker's clamp reckons with the width it draws at the Text Size", () => {
  // A Base button near the right edge: at 12 pt the 320 px popover shifts left to 696; at 18 pt (1.5)
  // it is 480 px wide, so it shifts further, to stay inside the window by the scaled margin.
  const button = rect(800, 40);
  expect(computePopoverStyle(button, page(1)).left).toBe(1024 - POPOVER_WIDTH - VIEWPORT_MARGIN);
  const large = computePopoverStyle(button, page(1.5));
  expect(large.left).toBe(1024 - POPOVER_WIDTH * 1.5 - VIEWPORT_MARGIN * 1.5);
  // Its gap under the button follows too.
  expect(large.top).toBe(button.bottom + POPOVER_GAP * 1.5);
  // Its width is the stylesheet's: capped at 86vw in a narrow window.
  expect(popoverWidth(1.5, 400)).toBeCloseTo(344);
});

test("the Base picker flips above when the room below is short of its scaled least height", () => {
  // 200 px under the button: 186 after the gap and margin, enough for the 160 px least height at
  // 12 pt; 179 at 18 pt, short of its 240.
  const button = rect(40, 768 - 24 - 200);
  expect(computePopoverStyle(button, page(1)).top).not.toBe("auto");
  expect(computePopoverStyle(button, page(1.5)).top).toBe("auto");
});

test("the Base picker places again when the scale changes while it is open", () => {
  // The effect in BranchBasePicker subscribes `reposition` with onInterfaceScaleChange; this is the
  // same wiring on a page.
  const view = page(1);
  const button = rect(800, 40);
  let placed = computePopoverStyle(button, view);
  const stop = onInterfaceScaleChange(() => {
    placed = computePopoverStyle(button, view);
  }, view);
  setScale(view, 1.5);
  stop();
  expect(placed.left).toBe(1024 - 480 - 12);
});

test("the location menu's side-picking heights follow the rows; the folder list's cap does not", () => {
  expect(locationMenuHeights(1)).toEqual({ tallest: 320, shortest: 220 });
  expect(locationMenuHeights(1.5)).toEqual({ tallest: 350, shortest: 330 });
});

test("a location menu that fits below at 12 pt opens above at 18 pt when its scaled least size does not", () => {
  // A control in a composer high in the window, with 260 px under the composer's foot and more above:
  // the shortest menu (220) fits below at 12 pt, not its 330 at 18 pt.
  const make = (view: Window) => {
    const composer = { getBoundingClientRect: () => rect(0, 400, 600, 100) };
    return {
      ownerDocument: view.document,
      getBoundingClientRect: () => rect(20, 470, 80, 22),
      closest: () => composer,
    } as unknown as Element;
  };
  const small = page(1, 1024, 760);
  expect(locationMenuSide(make(small), 760)).toBe("bottom");
  const large = page(1.5, 1024, 760);
  expect(locationMenuSide(make(large), 760)).toBe("top");
});

// The detector: each floating surface's frame (its width, max width, height and the like) is in
// `--ui-px`, never a bare px, so it grows with the type in it. `calc(100vw - Npx)` (a window margin)
// and a min-width floor are allowed. A new floating surface belongs on this list.
const SRC = join(import.meta.dir, "../src");
const FLOATING: Array<{ file: string; selector: string; properties: string[] }> = [
  { file: "styles.css", selector: ".base-picker-popover", properties: ["width", "max-width"] },
  {
    file: "agent-session/acpmux/contextCard.css",
    selector: ".acpmux-context-card.ui-card",
    properties: ["width", "max-width"],
  },
  {
    file: "agent-session/acpmux/contextCard.css",
    selector: ".acpmux-context-pop--compact.ui-card",
    properties: ["width", "max-width"],
  },
  {
    file: "agent-session/acpmux/planUsageCard.css",
    selector: ".acpmux-plan-pop.ui-card",
    properties: ["width", "max-width"],
  },
  {
    file: "agent-session/acpmux/needsYou/needsYou.css",
    selector: ".acpmux-needs-you",
    properties: ["width", "max-height"],
  },
  { file: "agent-session/acpmux/quickModelColumns.css", selector: ".acpmux-cols-card", properties: ["width"] },
  {
    file: "agent-session/acpmux/header/header.css",
    selector: ".acpmux-header-preview",
    properties: ["max-width", "padding"],
  },
  {
    file: "agent-session/acpmux/conversation/conversation.css",
    selector: ".cv-selection-reply",
    properties: ["height", "gap", "padding-inline", "line-height", "max-width"],
  },
  {
    file: "agent-session/acpmux/conversation/conversation.css",
    selector: '.cv-selection-reply[data-look="icon"]',
    properties: ["width"],
  },
  { file: "agent-session/acpmux/styles.css", selector: ".acpmux-file-search", properties: ["width", "padding"] },
  {
    file: "agent-session/acpmux/composerLocation.css",
    selector: ".acpmux-menu.acpmux-location-menu",
    properties: ["max-width"],
  },
  {
    file: "agent-session/acpmux/composerLocation.css",
    selector: ".acpmux-menu.acpmux-location-menu.acpmux-folder-popover",
    properties: ["max-width"],
  },
];

/** Every declaration of `property` in rules whose selector is exactly `selector`, in `css`. */
function declared(css: string, selector: string, property: string): string[] {
  const plain = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const values: string[] = [];
  for (const rule of plain.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (rule[1]!.trim() !== selector) continue;
    for (const decl of rule[2]!.split(";")) {
      const at = decl.indexOf(":");
      if (at > 0 && decl.slice(0, at).trim() === property) values.push(decl.slice(at + 1).trim());
    }
  }
  return values;
}

/** The px literals in `value` that do not follow Text Size. */
function barePx(value: string): string[] {
  const rest = value
    .replace(/var\(--ui-px,\s*1px\)/g, "")
    .replace(/calc\(\s*100(?:vw|vh|dvh|%)\s*-\s*[\d.]+px\s*\)/g, "")
    .replace(/var\(--[\w-]+(?:,\s*[^()]*(?:\([^()]*\))?)?\)/g, "");
  return [...rest.matchAll(/(?<![\w.-])[\d.]+px/g)].map((match) => match[0]);
}

test("every floating surface frames itself in --ui-px, so its frame grows with its type", () => {
  const problems: string[] = [];
  for (const { file, selector, properties } of FLOATING) {
    const css = readFileSync(join(SRC, file), "utf8");
    for (const property of properties) {
      const values = declared(css, selector, property);
      if (values.length === 0) problems.push(`${file} ${selector}: no ${property}`);
      for (const value of values) {
        const bare = barePx(value);
        if (bare.length > 0) problems.push(`${file} ${selector} { ${property}: ${value} } has ${bare.join(", ")}`);
      }
    }
  }
  expect(problems).toEqual([]);
});

test("the shared token is one px at the interface scale", () => {
  const css = readFileSync(join(SRC, "ui/popupSurface.css"), "utf8");
  expect(declared(css, ":root", "--ui-px")).toEqual(["calc(1px * var(--cmux-interface-scale, 1))"]);
});

test("the detector catches a bare px frame", () => {
  expect(barePx("320px")).toEqual(["320px"]);
  expect(barePx("min(86vw, 360px)")).toEqual(["360px"]);
  expect(barePx("min(calc(260 * var(--ui-px, 1px)), calc(100vw - 24px))")).toEqual([]);
});

// Which clicks the transcript holds, and the room a collapse keeps under the rows (foldAnchor.ts), so closing a disclosure at the
// transcript's end never clamps the offset and brings the clicked line down (Leo, ask-a736047107:
// "WHEN I EXPAND THEM IT JUMPS ME DOWN AND WHEN I COLLAPSE IT JUMPS ME UP").
import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  clickFold,
  FOLD_HOLD_MIN_MS,
  foldHoldTarget,
  foldHolding,
  foldRoomFor,
  foldToggleAt,
  holdFold,
  trimmedFoldRoom,
  verticalWheel,
} from "./foldAnchor";

describe("foldRoomFor", () => {
  test("keeps the view's end, whole pixels up", () => {
    expect(foldRoomFor(1200.4, 600)).toBe(1801);
  });
  test("never shrinks an end already kept further down", () => {
    expect(foldRoomFor(100, 600, 2000)).toBe(2000);
  });
});

describe("trimmedFoldRoom", () => {
  test("stays as it is while a fold holds its line", () => {
    expect(trimmedFoldRoom(1800, 1500, 1200, true)).toBe(1800);
  });
  test("follows the view's end up as the reader scrolls up", () => {
    expect(trimmedFoldRoom(1800, 1500, 1200, false)).toBe(1500);
  });
  test("never grows past what was kept", () => {
    expect(trimmedFoldRoom(1800, 1900, 1200, false)).toBe(1800);
  });
  test("goes once the rows reach it", () => {
    expect(trimmedFoldRoom(1800, 1800, 1800, false)).toBe(0);
    expect(trimmedFoldRoom(1800, 1500, 1600, false)).toBe(0);
  });
  test("goes once the view's own height covers it (rows shorter than the view)", () => {
    expect(trimmedFoldRoom(800, 640, 500, false, 640)).toBe(0);
  });
  test("nothing kept stays nothing", () => {
    expect(trimmedFoldRoom(0, 1500, 1200, false)).toBe(0);
  });
});

/// One transcript row holding `html`, inside a scroller.
function row(html: string) {
  const { document } = new JSDOM(
    `<div class="acpmux-scroll"><div class="acpmux-row" aria-posinset="1">${html}</div></div>`,
  ).window;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  return { document, scroller, at: (selector: string) => foldToggleAt(document.querySelector(selector), scroller) };
}

describe("foldToggleAt", () => {
  // Every control that opens or closes something in a row is held, so none of them moves the view.
  for (const [kind, html, selector] of [
    ["a tool line", '<button class="cv-tool is-toggle" aria-expanded="false"><span class="x">ls</span></button>', ".x"],
    [
      "a sent message's line (a div)",
      '<div class="cv-tool is-toggle cv-sent" role="button" aria-expanded="false"><b>to</b></div>',
      "b",
    ],
    [
      "Show more under a message",
      '<button class="cv-user__more cv-message__more" aria-expanded="false">Show more</button>',
      "button",
    ],
    [
      "Show all lines under an output",
      '<button class="cv-output-more" aria-expanded="false">Show all 80 lines</button>',
      "button",
    ],
    ["a sub-session's Raw", '<button class="cv-subsession__toggle" aria-expanded="false">Raw</button>', "button"],
    ["a file list's +N more", '<button class="acpmux-edited-more" aria-expanded="false">+3 more</button>', "button"],
    [
      "an agent message's words",
      '<div class="cv-tool cv-agentmsg__line"><span class="cv-agentmsg__words" data-interactive="">Asked</span></div>',
      "span",
    ],
    ["a summary", "<details><summary>Context</summary>body</details>", "summary"],
    ["a block's Wrap lines", '<button class="cv-codeblock__action" aria-pressed="false">wrap</button>', "button"],
    ["a diagram's chart or code", '<button class="cv-diagram__toggle">Code</button>', "button"],
    ["a question's pill", '<button class="acpmux-question-pill" aria-expanded="false">Q</button>', "button"],
    ["a permission's details", '<button class="acpmux-ask-toggle" aria-expanded="false">Details</button>', "button"],
    ["a paste chip", '<button class="cv-user__paste" aria-expanded="false">pasted</button>', "button"],
  ] as const) {
    test(`holds ${kind}`, () => {
      expect(row(html).at(selector)).toBeDefined();
    });
  }
  test("leaves a menu's trigger alone", () => {
    expect(row('<button aria-expanded="false" aria-haspopup="menu">…</button>').at("button")).toBeUndefined();
  });
  test("leaves a control inside a toggle alone (a sent line's recipient, its Copy)", () => {
    const { at } = row(
      '<div class="cv-tool is-toggle cv-sent" role="button" aria-expanded="false"><button class="to">lane</button><span class="w">Sent</span></div>',
    );
    expect(at(".to")).toBeUndefined();
    expect(at(".w")).toBeDefined();
  });
  test("leaves plain text alone", () => {
    expect(row("<p>words</p>").at("p")).toBeUndefined();
  });
});

describe("foldHoldTarget", () => {
  test("a line that opens a body under itself holds itself", () => {
    const { at } = row('<button class="cv-tool is-toggle" aria-expanded="false">ls</button>');
    expect(foldHoldTarget(at("button")!).tagName).toBe("BUTTON");
  });
  test("a control under its body holds its row's top, so the body grows down and shrinks up from there", () => {
    const { at } = row('<div>text</div><button class="cv-message__more" aria-expanded="false">Show more</button>');
    expect(foldHoldTarget(at("button")!).classList.contains("acpmux-row")).toBe(true);
  });
});

describe("foldHolding", () => {
  const toggle = { isConnected: true } as HTMLElement;
  test("holds until its time is up", () => {
    expect(foldHolding({ toggle, top: 0, until: 100 }, 50)).toBe(true);
    expect(foldHolding({ toggle, top: 0, until: 100 }, 101)).toBe(false);
  });
  test("lets go of a line that left the transcript", () => {
    expect(foldHolding({ toggle: { isConnected: false } as HTMLElement, top: 0, until: 100 }, 50)).toBe(false);
  });
  test("nothing held", () => {
    expect(foldHolding(undefined)).toBe(false);
  });
});

describe("hold timing", () => {
  const line = (top: number) =>
    ({ isConnected: true, getBoundingClientRect: () => ({ top }) }) as unknown as HTMLElement;
  test("a click keeps the place its press held, timed from the click", () => {
    const toggle = line(300);
    const pressed = { toggle, top: 200, until: 1_000 };
    const held = clickFold(toggle, pressed, 500);
    expect(held.top).toBe(200);
    expect(held.until).toBeGreaterThan(500);
  });
  test("a click on another line, or after its press let go, holds where the line is now", () => {
    const toggle = line(300);
    expect(clickFold(toggle, { toggle: line(0), top: 200, until: 1_000 }, 500).top).toBe(300);
    expect(clickFold(toggle, { toggle, top: 200, until: 400 }, 500).top).toBe(300);
  });
  test("a toggle with no fold (Reduce Motion) is still held while what it opened is placed", () => {
    const toggle = line(300);
    expect(holdFold(toggle, 1_000).until).toBeGreaterThanOrEqual(1_000 + FOLD_HOLD_MIN_MS);
  });
  test("only a vertical wheel lets go", () => {
    expect(verticalWheel({ deltaX: 0, deltaY: 40 })).toBe(true);
    expect(verticalWheel({ deltaX: 60, deltaY: 4 })).toBe(false);
  });
});

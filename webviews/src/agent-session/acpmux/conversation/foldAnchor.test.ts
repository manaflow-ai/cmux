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
  keepFold,
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
  // Show less under a long output, collapsed: the rows end above the view's top, so the kept room
  // would be all the reader sees. Once the hold is over it goes, and the view comes back to the rows.
  test("goes once the rows end above the view's top, so the view is never only room", () => {
    expect(trimmedFoldRoom(3000, 3000, 2200, false, 640)).toBe(0);
    // While the hold lasts the room stays (the held line is what keeps the view on the rows).
    expect(trimmedFoldRoom(3000, 3000, 2200, true, 640)).toBe(3000);
    // Rows still reaching into the view keep it: the clamp it prevents is what moved them.
    expect(trimmedFoldRoom(3000, 3000, 2500, false, 640)).toBe(3000);
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
      "an agent message's line",
      '<div class="cv-tool cv-agentmsg__line" data-header-toggle=""><span class="cv-agentmsg__words">Asked</span></div>',
      ".cv-agentmsg__words",
    ],
    [
      "the edits card's header, at its icon",
      '<div class="acpmux-edited-head" data-header-toggle=""><span class="acpmux-edited-icon"><svg></svg></span></div>',
      ".acpmux-edited-icon",
    ],
    ["a summary", "<details><summary>Context</summary>body</details>", "summary"],
    [
      "a block's Wrap lines",
      '<button class="cv-codeblock__action" aria-pressed="false" data-fold-toggle="">wrap</button>',
      "button",
    ],
    [
      "a tool output's Raw",
      '<button class="cv-tool-output__raw" aria-pressed="false" data-fold-toggle="">Raw</button>',
      "button",
    ],
    ["a diagram's chart or code", '<button class="cv-diagram__toggle">Code</button>', "button"],
    ["a question's pill", '<button class="acpmux-question-pill" aria-expanded="false">Q</button>', "button"],
    ["a permission's details", '<button class="acpmux-ask-toggle" aria-expanded="false">Details</button>', "button"],
    ["a paste chip", '<button class="cv-user__paste" aria-expanded="false">pasted</button>', "button"],
  ] as const) {
    test(`holds ${kind}`, () => {
      expect(row(html).at(selector)).toBeDefined();
    });
  }
  // A reply's own actions change nothing in its row's height: Pin and Read aloud are `aria-pressed`
  // like Wrap lines, but a click on one while the reply streams must neither hold the row nor stop
  // following the latest reply (App.tsx's folding pass calls follow(false) for a held line).
  for (const [kind, html] of [
    [
      "a reply's Pin",
      '<button class="cv-iconbtn cv-iconbtn--compact cv-message-pin" aria-pressed="false" aria-label="Pin">p</button>',
    ],
    [
      "a reply's Read aloud",
      '<button class="cv-iconbtn cv-iconbtn--compact cv-read-aloud" aria-pressed="false" aria-label="Read aloud">r</button>',
    ],
    [
      "a reply's Read aloud while it reads (Stop)",
      '<button class="cv-iconbtn cv-iconbtn--compact cv-read-aloud" aria-pressed="true" data-reading="true">s</button>',
    ],
  ] as const) {
    test(`leaves ${kind} alone, so a click while a reply streams neither holds nor unfollows`, () => {
      const { document, scroller } = row(
        `<div class="cv-agentmsg">streaming…</div><div class="cv-turn-actions cv-reply-actions"><span class="cv-turn-action-group">${html}</span></div>`,
      );
      const button = document.querySelector<HTMLElement>(".cv-turn-action-group button")!;
      // What App.tsx's pointerdown and click handlers do with the press and the click.
      const press = foldToggleAt(button, scroller);
      const pressed = press ? holdFold(foldHoldTarget(press, scroller)) : undefined;
      const click = foldToggleAt(button, scroller);
      const anchor = click ? clickFold(foldHoldTarget(click, scroller), pressed) : undefined;
      expect(press).toBeUndefined();
      expect(anchor).toBeUndefined();
      // The next placement pass: nothing held, so it is no folding pass and follows the latest row.
      const folding = Boolean(anchor && keepFold(anchor, scroller));
      expect(folding).toBe(false);
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
  test("leaves a file link inside a tool line alone", () => {
    const { at } = row(
      '<button class="cv-tool is-toggle" aria-expanded="false"><span class="f" role="link">App.tsx</span></button>',
    );
    expect(at(".f")).toBeUndefined();
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
  /// `scroller`'s view starting at viewport y 100, and the row's top at `rowTop`.
  const placed = (rowTop: number) => {
    const { at, scroller, document } = row(
      '<pre>long output</pre><button class="cv-output-more" aria-expanded="true">Show less</button>',
    );
    const rect = (top: number) => () => ({ top }) as DOMRect;
    scroller.getBoundingClientRect = rect(100);
    document.querySelector<HTMLElement>(".acpmux-row")!.getBoundingClientRect = rect(rowTop);
    return { toggle: at("button")!, scroller };
  };
  test("a row whose top is in view still holds by its top", () => {
    const { toggle, scroller } = placed(140);
    expect(foldHoldTarget(toggle, scroller).classList.contains("acpmux-row")).toBe(true);
  });
  // Show less under a long output, scrolled down to: the row's top is above the view. Held by it, the
  // collapsed row would end above the view and leave it blank (review BLOCK at 5e59e449), so the
  // control the reader clicked holds instead.
  test("a row whose top is above the view holds the clicked control", () => {
    const { toggle, scroller } = placed(-1800);
    expect(foldHoldTarget(toggle, scroller)).toBe(toggle);
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
    expect(holdFold(line(300), 1_000).until).toBeGreaterThanOrEqual(1_000 + FOLD_HOLD_MIN_MS);
  });
  test("a hold that puts its line back does not outlast its time", () => {
    let top = 120;
    const toggle = { isConnected: true, getBoundingClientRect: () => ({ top }) } as unknown as HTMLElement;
    const scroller = { scrollTop: 0 } as HTMLElement;
    const anchor = { toggle, top: 100, until: 200 };
    expect(keepFold(anchor, scroller, 190)).toBe(true);
    expect(scroller.scrollTop).toBe(20);
    expect(anchor.until).toBe(200);
    top = 140;
    expect(keepFold(anchor, scroller, 201)).toBe(false);
  });
  test("press, click, then the row's own anchored-collapse event: the line stays where it was pressed", () => {
    const toggle = line(300);
    const clicked = clickFold(toggle, { toggle, top: 200, until: 1_000 }, 500);
    expect(clickFold(toggle, clicked, 501).top).toBe(200);
  });
  test("only a vertical wheel lets go", () => {
    expect(verticalWheel({ deltaX: 0, deltaY: 40 })).toBe(true);
    expect(verticalWheel({ deltaX: 60, deltaY: 4 })).toBe(false);
  });
});

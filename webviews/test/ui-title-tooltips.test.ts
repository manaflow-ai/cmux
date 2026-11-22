import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { installTooltips, TOOLTIP_DELAY, tooltipPosition } from "../src/ui/titleTooltips";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe("tooltip placement", () => {
  const view = { width: 400, height: 300 };
  test("below the element, centered", () => {
    expect(tooltipPosition({ left: 100, top: 20, width: 40, height: 20 }, { width: 80, height: 24 }, view)).toEqual({
      left: 80,
      top: 46,
    });
  });
  /// The rail's last button sits at the pane's right edge: "More: closed sessions" stays whole.
  test("shifted inside the window's edge", () => {
    expect(tooltipPosition({ left: 380, top: 20, width: 20, height: 20 }, { width: 160, height: 24 }, view).left).toBe(
      234,
    );
    expect(tooltipPosition({ left: 0, top: 20, width: 20, height: 20 }, { width: 160, height: 24 }, view).left).toBe(6);
  });
  test("above the element when there is no room below", () => {
    expect(tooltipPosition({ left: 100, top: 270, width: 40, height: 20 }, { width: 80, height: 24 }, view).top).toBe(
      240,
    );
  });
});

describe("tooltips", () => {
  const setup = () => {
    const dom = new JSDOM(
      '<!doctype html><body><button id=a title="Sessions">a</button><button id=b title="History">b</button></body>',
    );
    const doc = dom.window.document;
    const uninstall = installTooltips(doc);
    const tip = () => doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
    const hover = (id: string) =>
      doc.getElementById(id)!.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
    const leave = (id: string) =>
      doc.getElementById(id)!.dispatchEvent(new dom.window.MouseEvent("pointerout", { bubbles: true }));
    return { doc, uninstall, tip, hover, leave };
  };

  test("shows after a short hover, without the native title", async () => {
    const { doc, uninstall, tip, hover } = setup();
    hover("a");
    expect(doc.getElementById("a")!.hasAttribute("title")).toBe(false);
    expect(tip().hidden).toBe(true);
    await sleep(TOOLTIP_DELAY + 50);
    expect(tip().hidden).toBe(false);
    expect(tip().textContent).toBe("Sessions");
    uninstall();
  });

  test("moving to the next button shows its tooltip at once", async () => {
    const { uninstall, tip, hover, leave } = setup();
    hover("a");
    await sleep(TOOLTIP_DELAY + 50);
    leave("a");
    hover("b");
    expect(tip().hidden).toBe(false);
    expect(tip().textContent).toBe("History");
    uninstall();
  });

  test("an icon button keeps its title as its name; a named one is left alone", () => {
    const dom = new JSDOM(
      '<!doctype html><body><button id=icon title="More"></button><button id=text title="Sessions">Chats</button></body>',
    );
    const doc = dom.window.document;
    const uninstall = installTooltips(doc);
    for (const id of ["icon", "text"])
      doc.getElementById(id)!.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
    expect(doc.getElementById("icon")!.getAttribute("aria-label")).toBe("More");
    expect(doc.getElementById("text")!.hasAttribute("aria-label")).toBe(false);
    uninstall();
  });

  test("a click puts it away and the next one waits again", async () => {
    const { doc, uninstall, tip, hover } = setup();
    hover("a");
    await sleep(TOOLTIP_DELAY + 50);
    doc.getElementById("a")!.dispatchEvent(new doc.defaultView!.MouseEvent("pointerdown", { bubbles: true }));
    expect(tip().hidden).toBe(true);
    hover("b");
    expect(tip().hidden).toBe(true);
    uninstall();
    expect(doc.querySelector(".ui-title-tooltip")).toBeNull();
  });
});

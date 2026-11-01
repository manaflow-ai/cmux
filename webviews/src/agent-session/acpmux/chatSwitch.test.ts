// The chat switch motion's parts (chatSwitch.ts): every arm settles within the 240 ms ceiling, moves
// only transform and opacity, picks only the rows on screen (bottom first), and plays nothing when
// the host turned motion off.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { chatSwitchParts, playChatSwitch } from "./chatSwitch";

const CEILING_MS = 240;

/** A transcript 400 px tall with rows of 60 px from `top`, the title and Session Info's body. */
function pane(rowTops: number[]) {
  const dom = new JSDOM(
    `<!doctype html><html><body>
      <span class="acpmux-thread-title">Title</span>
      <div class="acpmux-scroll">${rowTops.map((top) => `<div class="acpmux-row" data-top="${top}"></div>`).join("")}</div>
      <aside class="acpmux-session-info"><div class="acpmux-session-info__body"></div></aside>
    </body></html>`,
  );
  const doc = dom.window.document;
  const rect = (top: number, height: number) =>
    ({ top, bottom: top + height, height, left: 0, right: 600, width: 600, x: 0, y: top }) as DOMRect;
  const scroller = doc.querySelector<HTMLElement>(".acpmux-scroll")!;
  scroller.getBoundingClientRect = () => rect(0, 400);
  for (const row of doc.querySelectorAll<HTMLElement>(".acpmux-row")) {
    const top = Number(row.dataset.top);
    row.getBoundingClientRect = () => rect(top, 60);
  }
  return { doc, scroller };
}

test("every arm settles within the ceiling and moves only transform and opacity", () => {
  const { scroller } = pane([-200, 0, 60, 120, 180, 240, 300, 360, 420, 480, 540, 600, 660, 720]);
  for (const arm of ["fade", "stagger", "depth"] as const) {
    for (const reduced of [false, true]) {
      const parts = chatSwitchParts(scroller, arm, reduced);
      expect(parts.length).toBeGreaterThan(0);
      for (const part of parts) {
        expect(part.delay + part.duration).toBeLessThanOrEqual(CEILING_MS);
        for (const frame of [part.from, part.to])
          for (const key of Object.keys(frame)) expect(["opacity", "transform"]).toContain(key);
        // Reduce Motion: a fade, no travel.
        if (reduced) expect("transform" in part.from).toBe(false);
      }
    }
  }
});

test("stagger moves the rows on screen, bottom first, and none off screen", () => {
  const { doc, scroller } = pane([-200, 0, 120, 240, 360, 500]);
  const rows = chatSwitchParts(scroller, "stagger", false)
    .map((part) => part.element)
    .filter((element) => element.classList.contains("acpmux-row")) as HTMLElement[];
  expect(rows.map((row) => row.dataset.top)).toEqual(["360", "240", "120", "0"]);
  // The title and Session Info's body move too.
  const elements = chatSwitchParts(scroller, "stagger", false).map((part) => part.element);
  expect(elements).toContain(doc.querySelector(".acpmux-thread-title")!);
  expect(elements).toContain(doc.querySelector(".acpmux-session-info__body")!);
});

test("off, and motion off, play nothing", () => {
  const { doc, scroller } = pane([0, 60]);
  scroller.animate = () => {
    throw new Error("animated");
  };
  expect(playChatSwitch(scroller, "off")).toBeUndefined();
  doc.documentElement.dataset.cmuxMotion = "off";
  expect(playChatSwitch(scroller, "stagger")).toBeUndefined();
});

// The frame-read rule (scripts/check-frame-reads.ts): browser tests read layout after a frame has
// painted, never in its requestAnimationFrame callback.
import { expect, test } from "bun:test";
import { checkFrameReadsSource } from "../scripts/check-frame-reads";

const browserTest = (body: string) => `import { chromium } from "playwright";\n${body}\n`;
const check = (body: string) => checkFrameReadsSource("/x/test/a.test.ts", browserTest(body));

test("a sampler that reschedules itself from its frame callback is named, with its line", () => {
  const errors = check(`
const tick = () => {
  frames.push(row.getBoundingClientRect().top);
  requestAnimationFrame(tick);
};
requestAnimationFrame(tick);`);
  expect(errors).toHaveLength(1);
  expect(errors[0]).toContain(":5: samples every frame in a requestAnimationFrame callback (tick)");
  expect(
    check(`function look(now) { if (now < end) window.requestAnimationFrame(look); }\nrequestAnimationFrame(look);`),
  ).toHaveLength(1);
});

test("a frame callback that reads layout is named; one that only writes passes", () => {
  expect(
    check(`requestAnimationFrame(() => requestAnimationFrame(() => resolve(box.getBoundingClientRect())));`),
  ).toHaveLength(1);
  expect(check(`requestAnimationFrame(() => { done(scroller.scrollTop); });`)).toHaveLength(1);
  expect(check(`requestAnimationFrame(() => { scroller.scrollTop = 0; shown = true; });`)).toEqual([]);
  // A read in a function the callback only defines runs later, so it is that function's own.
  expect(check(`requestAnimationFrame(() => setTimeout(() => read(el.offsetTop), 0));`)).toEqual([]);
});

test("a frame awaiter is named, named or awaited before a read; a wait the test awaits passes", () => {
  const errors = check(`const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));`);
  expect(errors).toHaveLength(1);
  expect(errors[0]).toContain("awaits a frame in frame()");
  expect(
    check(
      `await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));`,
    ),
  ).toEqual([]);
  // Awaited inside the page and then read, the read runs before that frame's layout and paint.
  expect(
    check(`await page.evaluate(async () => {
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  return box.getBoundingClientRect().top;
});`)[0],
  ).toContain(":3: awaits a frame and then reads layout before the frame paints");
  expect(
    check(`await page.evaluate(async () => {
  await new Promise((resolve) => requestAnimationFrame(resolve));
  shown = true;
});`),
  ).toEqual([]);
  expect(
    check(`await page.evaluate(async () => {
  scroller.scrollTop = scroller.scrollHeight - scroller.clientHeight;
  await new Promise((resolve) => requestAnimationFrame(resolve));
});`),
  ).toEqual([]);
});

test("the painted-frame helpers pass, and a read in a frame callback can say why", () => {
  expect(
    check(`window.cmuxAfterPaint((frame) => { frames.push(row.getBoundingClientRect().top); });
await window.cmuxPaintFrame(() => { scroller.scrollTop += 100; });`),
  ).toEqual([]);
  expect(
    check(`// raf-read: measures the layout the frame's own callbacks leave
requestAnimationFrame(() => done(el.offsetHeight));`),
  ).toEqual([]);
  expect(check(`// raf-read:\nrequestAnimationFrame(() => done(el.offsetHeight));`)).toHaveLength(1);
});

test("a test that opens no browser is not checked", () => {
  expect(
    checkFrameReadsSource("a.test.ts", "const tick = () => { el.offsetTop; requestAnimationFrame(tick); };"),
  ).toEqual([]);
});

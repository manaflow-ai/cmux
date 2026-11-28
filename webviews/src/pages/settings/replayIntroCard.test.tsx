// Settings > General, right under Text Size: Replay the Intro reopens the Make cmux Yours step on the current
// settings through the palette's home.makeItYours (decision d-eedbe6969c; Leo: "and i guess they can maybe replay
// it to return to the walk of the settings"). The card only runs the action: it writes no setting.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage } = await import("./testing");
let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

test("General's Replay the Intro card sits right under Text Size, ahead of every row", async () => {
  page = await renderPage({ path: "/settings/general" });
  const section = page.container.querySelector<HTMLElement>(".section[data-section='general']")!;
  const cards = [...section.querySelectorAll<HTMLElement>("[data-card]")].map((card) => card.dataset.card);
  const textSize = cards.indexOf("textSize");
  expect(textSize).toBeGreaterThanOrEqual(0);
  expect(cards.slice(textSize, textSize + 2)).toEqual(["textSize", "replayIntro"]);
  const card = section.querySelector<HTMLElement>("[data-card='replayIntro']")!;
  expect(card.textContent).toContain("Replay the Intro");
});

test("Replay runs home.makeItYours and writes no setting", async () => {
  page = await renderPage({ path: "/settings/general" });
  const before = page.provider.log.length;
  const button = page.container.querySelector<HTMLButtonElement>("[data-card='replayIntro'] button[data-action]")!;
  await click(button);
  expect(ops(page.provider, "cmux.app.action.run")).toEqual([{ action: "home.makeItYours" }]);
  const writes = page.provider.log.slice(before).filter((entry) => /set|write|reset/i.test(entry.op));
  expect(writes).toEqual([]);
});

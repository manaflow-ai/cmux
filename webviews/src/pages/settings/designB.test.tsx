import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(restore);
const { renderPage, rowElement, click, changeValue, fire, ops } = await import("./testing");
let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

test("font search escapes the scroll container and supports keyboard selection", async () => {
  page = await renderPage({ path: "/settings/appearance" });
  const row = rowElement(page.container, "terminal.fontFamily");
  await click(row.querySelector(".domain-button")!);
  const panel = document.querySelector(".domain-panel")!;
  expect(panel.closest(".content") === null).toBe(true);
  const input = panel.querySelector<HTMLInputElement>("input")!;
  await changeValue(input, "Menlo");
  await fire(input, "keydown", { key: "ArrowDown" });
  await fire(input, "keydown", { key: "Enter" });
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "terminal.fontFamily", value: "Menlo" }]);
  expect(document.querySelector(".domain-panel")).toBeNull();
});

test("a failed write replaces the hint and retry replays only that setting", async () => {
  page = await renderPage({
    path: "/settings/privacy",
    mock: { failing: { "cmux.settings.set": "cmux.settings.permission_denied" } },
  });
  const row = rowElement(page.container, "history.terminalCommands");
  await click(row.querySelector("[role=switch]")!);
  expect(row.querySelector(".row-help") === null).toBe(true);
  expect(row.textContent).toContain("Not saved");
  await click(row.querySelector("[data-save-retry]")!);
  const writes = ops(page.provider, "cmux.settings.set");
  expect(writes).toHaveLength(2);
  expect(writes[0]).toEqual(writes[1]);
});

test("font search has an empty result and Escape returns to its trigger", async () => {
  page = await renderPage({ path: "/settings/appearance" });
  const trigger = rowElement(page.container, "terminal.fontFamily").querySelector<HTMLButtonElement>(".domain-button")!;
  trigger.focus();
  await click(trigger);
  const input = document.querySelector<HTMLInputElement>(".domain-panel input")!;
  await changeValue(input, "no-such-font-123");
  expect(document.querySelector(".domain-panel")?.textContent).toContain("No matches. Try another name.");
  await fire(input, "keydown", { key: "Escape" });
  expect(document.querySelector(".domain-panel")).toBeNull();
  expect(document.activeElement === trigger).toBe(true);
});

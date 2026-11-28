// cx-d0d.23 Clear Browsing Data: an expanded browser profile clears its history, cookies and
// cache over a time range inline (no sheet), through the one `browserProfile.clearBrowsingData`
// action the palette, the CLI and MCP also run.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

test("a browser profile clears the chosen kinds of browsing data over the chosen range", async () => {
  const page = await renderPage({ path: "/settings/browser" });
  const row = page.container.querySelector<HTMLElement>('[data-profile="p-work"]')!;
  await act(async () => row.querySelector<HTMLButtonElement>(".host-toggle")!.click());
  const form = row.querySelector<HTMLElement>("[data-clear-browsing-data]");
  expect(form).not.toBeNull();
  const range = form!.querySelector<HTMLSelectElement>("select")!;
  // Chrome's default: the last hour.
  expect(range.value).toBe("hour");
  await act(async () => {
    range.value = "week";
    range.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await act(async () => form!.querySelector<HTMLInputElement>('input[name="cache"]')!.click());
  await act(async () => form!.querySelector<HTMLButtonElement>("[data-clear]")!.click());
  await settle();
  const run = page.provider.log.filter((entry) => entry.op === "cmux.app.action.run").at(-1)!;
  expect(run.params).toEqual({
    action: "browserProfile.clearBrowsingData",
    args: { range: "week", history: true, cookies: true, cache: false },
    target: "browser-profile:p-work",
  });
  expect(form!.querySelector("[data-cleared]")).not.toBeNull();
  page.unmount();
});

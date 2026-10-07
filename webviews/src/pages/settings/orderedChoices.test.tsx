// sidebar.workspaceRow.secondLineOrder (a string_list with choices): the page lists every choice in
// the order that applies (stored values first, the rest in schema order) and moves one up or down.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { orderedChoiceValues } from "./editors/OrderedChoicesEditor";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, rowElement } = await import("./testing");
const key = "sidebar.workspaceRow.secondLineOrder";

test("stored values come first, unknown values drop, missing choices follow in order", () => {
  expect(orderedChoiceValues(["a", "b", "c"], ["c", "x", "c"])).toEqual(["c", "a", "b"]);
  expect(orderedChoiceValues(["a", "b"], "a")).toEqual(["a", "b"]);
});

test("the second line order lists every item and writes the moved order", async () => {
  const page = await renderPage({ path: "/settings/appearance", mock: { values: { [key]: ["branch"] } } });
  const row = () => rowElement(page.container, key);
  const order = () => [...row().querySelectorAll("[data-choice]")].map((item) => item.getAttribute("data-choice"));
  expect(order()).toEqual(["branch", "directory", "process", "agentStatus", "ports", "lastActivity"]);
  const down = row().querySelector<HTMLButtonElement>('[data-choice="branch"] button[aria-label^="Move Down"]')!;
  await act(async () => down.click());
  await settle();
  const sets = page.provider.log.filter((entry) => entry.op === "cmux.settings.set");
  expect(sets.at(-1)!.params).toMatchObject({
    key,
    value: ["directory", "branch", "process", "agentStatus", "ports", "lastActivity"],
  });
  page.unmount();
});

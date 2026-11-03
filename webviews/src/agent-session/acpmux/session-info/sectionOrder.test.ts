import { expect, test } from "bun:test";
import { MORE_SECTIONS, PRIORITY_SECTIONS, parseOrder, registerAppSectionIds, resetSectionOrderForTests, sectionOrder } from "./sectionOrder";
test("app sections follow the built-in defaults by default", () => {
  resetSectionOrderForTests(); registerAppSectionIds(["app:github#prs"]);
  const order = sectionOrder();
  expect(order.slice(0, PRIORITY_SECTIONS.length)).toEqual(PRIORITY_SECTIONS);
  expect(order[PRIORITY_SECTIONS.length]).toBe("app:github#prs");
  expect(order.slice(-MORE_SECTIONS.length)).toEqual(MORE_SECTIONS);
});
test("a saved app id survives when its app is uninstalled", () => {
  resetSectionOrderForTests();
  expect(parseOrder(JSON.stringify(["environment", "app:old#section", "context"]))).toContain("app:old#section");
});

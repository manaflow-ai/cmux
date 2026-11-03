import { expect, test } from "bun:test";
import { settingsReadySelector } from "./settingsPasswords";

test("an empty settings card counts as mounted when its category has no row controls", () => {
  const selector = settingsReadySelector(true);
  expect(selector).toContain("[data-card][data-empty]");
  expect(settingsReadySelector(false)).toBe("[data-card]");
});

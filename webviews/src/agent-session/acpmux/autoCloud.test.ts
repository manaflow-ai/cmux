import { expect, test } from "bun:test";
import { autoCloudOn, autoPlaceForDigit } from "./autoCloud";

test("the cloud leg needs both the hidden key and an active plan", () => {
  expect(autoCloudOn({ key: true, plan: { state: "active" } })).toBe(true);
  expect(autoCloudOn({ key: false, plan: { state: "active" } })).toBe(false);
  expect(autoCloudOn({ key: true, plan: { state: "none" } })).toBe(false);
});

test("⌥⌘1–3 name Auto, Cloud only and Machine…; other digits name nothing", () => {
  expect([1, 2, 3].map(autoPlaceForDigit)).toEqual(["auto", "cloudOnly", "machine"]);
  expect(autoPlaceForDigit(4)).toBeUndefined();
  expect(autoPlaceForDigit(0)).toBeUndefined();
});

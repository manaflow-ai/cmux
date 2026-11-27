import { expect, test } from "bun:test";
import { fastModeIsOn, nextFastModeValue } from "./fastModeState";

test("tiered Fast mode treats every non-off tier as on and toggles to off", () => {
  const option = { currentValue: "ultrafast", onValue: "fast", offValue: "off" };
  expect(fastModeIsOn(option)).toBe(true);
  expect(nextFastModeValue(option)).toBe("off");
  expect(nextFastModeValue({ ...option, currentValue: "off" }, "ultrafast")).toBe("ultrafast");
  expect(nextFastModeValue({ ...option, currentValue: "off" }, "ultrafast", ["off", "fast"])).toBe("fast");
});

test("an unset Fast mode is off and toggles to its first on value", () => {
  const option = { currentValue: undefined, onValue: "fast", offValue: "off" };
  expect(fastModeIsOn(option)).toBe(false);
  expect(nextFastModeValue(option)).toBe("fast");
});

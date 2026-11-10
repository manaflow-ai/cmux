import { afterEach, expect, test } from "bun:test";
import { MODEL_MENU_MIN_WIDTH, modelMenuWidth, setModelMenuWidth } from "./modelMenuWidth";

afterEach(() => setModelMenuWidth(undefined));

test("a dragged width is kept, never under the floor, and a reset goes back to the default", () => {
  expect(modelMenuWidth()).toBeUndefined();
  setModelMenuWidth(512.4);
  expect(modelMenuWidth()).toBe(512);
  setModelMenuWidth(40);
  expect(modelMenuWidth()).toBe(MODEL_MENU_MIN_WIDTH);
  setModelMenuWidth(undefined);
  expect(modelMenuWidth()).toBeUndefined();
});

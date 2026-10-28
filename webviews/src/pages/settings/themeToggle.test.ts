// Match System Appearance turned on or off (ThemeStudio's toggledPair), for the terminal and the app theme.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { toggledPair } = await import("./components/ThemeStudio");

test("on: the theme in effect keeps its side, the other side takes that side's default", () => {
  expect(toggledPair({ kind: "single", name: "Dracula" }, true, "dark", "Apple System Colors")).toEqual({
    kind: "pair",
    light: "Apple System Colors Light",
    dark: "Dracula",
  });
  expect(toggledPair({ kind: "single", name: "GitHub Light" }, true, "light", "Apple System Colors Light")).toEqual({
    kind: "pair",
    light: "GitHub Light",
    dark: "Apple System Colors",
  });
});

test("on with no theme set: the fallback of the system appearance in effect", () => {
  expect(toggledPair(null, true, "dark", "Apple System Colors")).toEqual({
    kind: "pair",
    light: "Apple System Colors Light",
    dark: "Apple System Colors",
  });
});

test("off: the side the system shows now becomes the one theme", () => {
  const pair = { kind: "pair", light: "GitHub Light", dark: "Dracula" } as const;
  expect(toggledPair(pair, false, "dark", "x")).toEqual({ kind: "single", name: "Dracula" });
  expect(toggledPair(pair, false, "light", "x")).toEqual({ kind: "single", name: "GitHub Light" });
});

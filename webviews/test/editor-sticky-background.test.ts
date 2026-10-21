import { expect, test } from "bun:test";
import { editorStickyBackground } from "../src/pages/editor/colors";

for (const background of ["#123", "#123f", "#123456", "#123456ff", "#ABCDEFff"]) {
  test(`sticky scroll follows an opaque editor background: ${background}`, () => {
    expect(editorStickyBackground(background, "#abcdefeb")).toBe(background);
  });
}
for (const background of [null, "#1230", "#123e", "#12345600", "#12345680", "#123456fe"]) {
  test(`sticky scroll keeps its readable background for transparency: ${background}`, () => {
    expect(editorStickyBackground(background, "#abcdefeb")).toBe("#abcdefeb");
  });
}

test("a sticky color the theme sets itself wins over an opaque editor background", () => {
  expect(editorStickyBackground("#123456", "#abcdef", true)).toBe("#abcdef");
  expect(editorStickyBackground(null, "#abcdef", true)).toBe("#abcdef");
});

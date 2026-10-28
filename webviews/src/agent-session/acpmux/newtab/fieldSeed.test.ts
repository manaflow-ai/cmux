import { describe, expect, test } from "bun:test";
import { parseFieldSeed } from "./fieldSeed";

describe("parseFieldSeed", () => {
  test("takes the stand-in's text, selection and Return", () => {
    expect(parseFieldSeed({ text: "hi", selectionStart: 2, selectionEnd: 2, submit: true })).toEqual({
      text: "hi",
      selectionStart: 2,
      selectionEnd: 2,
      submit: true,
    });
  });

  test("clamps a selection past the text and orders its ends", () => {
    expect(parseFieldSeed({ text: "ab", selectionStart: 5, selectionEnd: 1, submit: false })).toEqual({
      text: "ab",
      selectionStart: 2,
      selectionEnd: 2,
      submit: false,
    });
  });

  test("refuses anything that is not a seed", () => {
    expect(parseFieldSeed(null)).toBeUndefined();
    expect(parseFieldSeed({ text: 3, selectionStart: 0, selectionEnd: 0 })).toBeUndefined();
  });
});

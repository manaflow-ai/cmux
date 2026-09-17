import { expect, test } from "bun:test";
import { insertComposerToken } from "./composerTokens";

test("composer token insertion appends at the cursor", () => {
  expect(insertComposerToken({ text: "", selectionStart: 0, selectionEnd: 0, token: "@" })).toEqual({
    text: "@",
    cursor: 1,
  });
});

test("composer token insertion separates from preceding text", () => {
  expect(
    insertComposerToken({ text: "ask about", selectionStart: 9, selectionEnd: 9, token: "$" }),
  ).toEqual({
    text: "ask about $",
    cursor: 11,
  });
});

test("composer token insertion replaces selected text", () => {
  expect(insertComposerToken({ text: "ask file", selectionStart: 4, selectionEnd: 8, token: "@" })).toEqual({
    text: "ask @",
    cursor: 5,
  });
});

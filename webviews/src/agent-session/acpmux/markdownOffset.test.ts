// The composer maps the caret, counted in what the prompt shows, into its markdown for @ mentions,
// + Mention and Search Files (MentionMenu.tsx markdownOffset). The editor counts an attachment placed
// in the text as one place, and the markdown holds its whole token (attachments.ts inlineToken).
// Review of #26545: counted per character, a caret after an attachment fell inside its id, so a
// mention read the id and an insert wrote into the token.
import { expect, test } from "bun:test";
import { inlineToken } from "./attachments";
import { markdownOffset, mentionQuery } from "./MentionMenu";

test("an attachment before the caret counts as one shown place", () => {
  const token = inlineToken("6f1d2c3a-1b2c-4d5e-8f90-123456789abc");
  const markdown = `look ${token} @fo`;
  // What shows: "look ", the atom, " @fo".
  const caret = "look ".length + 1 + " @fo".length;
  expect(markdownOffset(markdown, caret)).toBe(markdown.length);
  expect(mentionQuery(markdown, markdownOffset(markdown, caret))).toEqual({
    start: markdown.length - "@fo".length,
    query: "fo",
  });
  // Right after the atom: past its whole token, never inside it.
  expect(markdownOffset(markdown, "look ".length + 1)).toBe(`look ${token}`.length);
});

test("escapes and character references still show as one, beside an attachment", () => {
  const token = inlineToken("a1");
  const markdown = `\\_x&#x20;${token}y`;
  expect(markdownOffset(markdown, 1)).toBe(2);
  expect(markdownOffset(markdown, 3)).toBe("\\_x&#x20;".length);
  expect(markdownOffset(markdown, 4)).toBe(`\\_x&#x20;${token}`.length);
  expect(markdownOffset(markdown, 5)).toBe(markdown.length);
});

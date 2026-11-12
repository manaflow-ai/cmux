// https://github.com/manaflow-ai/cmux/issues/41016: an image pasted into the New Tab field showed
// its id. The field's typed text holds each pasted image as its token (U+FFFC, the attachment's
// id, U+FFFC), and the web search row drew and searched that text as it was: "Search the web for
// ￼0ffcff4e-…￼ look at this".
import { expect, test } from "bun:test";
import { inlineToken, withoutInlineTokens } from "../attachments";
import { EMPTY_OMNIBAR, omnibarContext } from "../omnibar";
import { screenRows, searchWords } from "./screenModel";

const omnibar = omnibarContext(EMPTY_OMNIBAR)!;
const ask = { harness: "claude", agent: "Claude Code" };
const id = "0ffcff4e-5219-4332-9ceb-9d0acc03a47a";
const rows = (typed: string) => searchWords(screenRows(typed, { omnibar, ask }), (text) => withoutInlineTokens(text));

test("the web search row of a draft with a pasted image searches its words, never the image's id", () => {
  const typed = `${inlineToken(id)} look at this`;
  const search = rows(typed).find((row) => row.type === "search");
  expect(search).toEqual({ type: "search", text: "look at this" });
  // The Ask row still sends the draft as it is: its image goes with it, in its place.
  expect(rows(typed).find((row) => row.type === "ask")).toMatchObject({ type: "ask", text: typed });
});

test("a draft of pasted images alone has no web search row", () => {
  const typed = `${inlineToken(id)}${inlineToken("37e67889-51d8-415a-beed-6d890ed57505")}`;
  expect(rows(typed).some((row) => row.type === "search")).toBe(false);
  expect(rows(typed).some((row) => row.type === "ask")).toBe(true);
});

test("a draft with no attachment keeps its search row as typed", () => {
  expect(rows("weather in tokyo").find((row) => row.type === "search")).toEqual({
    type: "search",
    text: "weather in tokyo",
  });
});

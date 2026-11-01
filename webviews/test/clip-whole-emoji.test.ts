// l10n-allow-file: test fixture text, not shipped UI.
// A title, preview or chip cut with an ellipsis never ends inside an emoji: a cut between its two
// UTF-16 units left a lone high surrogate, drawn as a replacement box and copied as one.
import { expect, test } from "bun:test";
import { promptTitle } from "../src/agent-session/acpmux/subagents/agentRuns";
import { pasteName } from "../src/agent-session/acpmux/conversation/promptCollapse";
import { shortCommand } from "../src/agent-session/acpmux/conversation/shortCommand";
import { promptSuggestion } from "../src/agent-session/acpmux/promptSuggestion";
import { threadTitle } from "../src/pages/home-channels/model";
import { sliceWhole, sliceWholeEnd } from "../src/ui/wholeChars";

/** A lone surrogate: a high unit not followed by a low one, or a low one not preceded by a high one. */
const lone = (text: string) => !text.isWellFormed();

test("sliceWhole and sliceWholeEnd move off the middle of an emoji", () => {
  expect(sliceWhole("ab😀cd", 3)).toBe("ab");
  expect(sliceWhole("ab😀cd", 4)).toBe("ab😀");
  expect(sliceWhole("ab", 9)).toBe("ab");
  expect(sliceWhole("ab", -1)).toBe("");
  expect(sliceWholeEnd("ab😀cd", 3)).toBe("cd");
  expect(sliceWholeEnd("ab😀cd", 4)).toBe("😀cd");
  expect(sliceWholeEnd("ab", 9)).toBe("ab");
});

test("a Home thread title cut at its limit keeps an emoji whole", () => {
  const text = `${"a".repeat(118)}😀 tail`;
  const root = { parts: [{ type: "text", text, mentions: [] }] } as never;
  const title = threadTitle(root);
  expect(lone(title)).toBe(false);
  expect(title).toBe(`${"a".repeat(118)}…`);
});

test("a run card's title cut at its limit keeps an emoji whole", () => {
  const title = promptTitle(`${"a".repeat(118)}😀 tail`)!;
  expect(lone(title)).toBe(false);
  expect(title).toBe(`${"a".repeat(118)}…`);
});

test("a paste chip's name cut at its limit keeps an emoji whole", () => {
  const name = pasteName(`${"a".repeat(38)}😀 tail`);
  expect(lone(name)).toBe(false);
  expect(name).toBe(`${"a".repeat(38)}…`);
});

test("a short command cut at its limit keeps an emoji whole", () => {
  const text = shortCommand(`echo ${"a".repeat(53)}😀tail`, 60);
  expect(lone(text)).toBe(false);
});

test("the suggested PR's title cut at its limit keeps an emoji whole", () => {
  const live = { number: 7, title: `${"a".repeat(58)}😀 tail`, state: "open", checks: "none" };
  const suggestion = promptSuggestion(undefined, { cwd: "/work/app" }, Date.now(), live)!;
  expect(lone(suggestion.title)).toBe(false);
  expect(suggestion.title).toBe(`${"a".repeat(58)}…`);
});

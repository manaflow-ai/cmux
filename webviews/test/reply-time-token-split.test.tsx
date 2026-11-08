// l10n-allow-file: test fixtures, not shipped UI.
// Leo, 2026-11-08, on the reply time's tooltip: "are the input tokens truly accurate, or is there
// some sort of wonky accounting going on? ... I feel like you're overcounting it by a bit. Perhaps we
// can also just ... say cached, uncached, perhaps, like, amount from context". Every count acpmux
// records for a turn is its model calls added up, and each call reads the whole context again, so
// the old "↑ in" (fresh input + cache reads + cache writes, over every call) was many times what the
// context held. The numbers here are real turns: an acpmux turn_result beside its Claude Code
// transcript (assistant messages deduped by id), and a Codex rollout's token_count events.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { TurnFooter } from "../src/agent-session/acpmux/conversation/TurnRows";
import { readTokens, replyTimeDetail, tokenRows } from "../src/agent-session/acpmux/conversation/turnTokensModel";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  addSplit,
  cachedTokens,
  callTokenSplit,
  NO_TOKENS,
  resultTokenSplit,
  uncachedTokens,
} from "../src/agent-session/acpmux/tokenSplit";

const t = translatorFor("en");

// A Claude turn of 58 calls: Claude Code's result `usage` (the calls added up), and the context
// after its last call (2 + 2,239 + 122,377 read, 709 written).
const CLAUDE_58 = {
  inputTokens: 112,
  cacheWriteTokens: 124_616,
  cacheReadTokens: 4_530_027,
  outputTokens: 23_702,
  contextTokens: 125_327,
  modelCalls: 58,
  inputExcludesCache: true,
};
const CLAUDE_CHAT = { harness: "claude", family: "claude" };
const CODEX_CHAT = { harness: "codex", family: "codex" };

test("a multi-call Claude turn: its input is counted once, uncached apart from cached, with its context", () => {
  const split = resultTokenSplit(CLAUDE_58)!;
  // The per-call sum, what the old "↑ 4.7M in" said: 37 times what the context held.
  expect(readTokens(split)).toBe(4_654_755);
  expect(uncachedTokens(split)).toBe(124_728);
  expect(cachedTokens(split)).toBe(4_530_027);
  expect(split.context).toBe(125_327);
  expect(split.calls).toBe(58);
  expect(tokenRows(t, "en", split)).toEqual([
    "Output 23.7K",
    "Input across calls 124.7K\u00a0uncached · 4.5M\u00a0cached",
    "Context at end 125.3K",
    "Model calls 58",
  ]);
});

test("the running turn adds its calls up and keeps the main loop's newest context", () => {
  // The first three calls of a real turn, then a subagent's (which names no context).
  const calls = [
    { inputTokens: 2, cachedWriteTokens: 6_246, cachedReadTokens: 125_325, outputTokens: 476, contextTokens: 132_049 },
    { inputTokens: 2, cachedWriteTokens: 895, cachedReadTokens: 131_571, outputTokens: 249, contextTokens: 132_717 },
    { inputTokens: 2, cachedWriteTokens: 663, cachedReadTokens: 132_466, outputTokens: 392, contextTokens: 133_523 },
    { inputTokens: 5, cachedWriteTokens: 0, cachedReadTokens: 9_000, outputTokens: 70 },
  ];
  const split = calls.reduce((sum, call) => addSplit(sum, callTokenSplit(call, call.outputTokens)!), NO_TOKENS);
  expect(readTokens(split)).toBe(406_177);
  expect(uncachedTokens(split)).toBe(7_815);
  expect(cachedTokens(split)).toBe(398_362);
  expect(split.output).toBe(1_187);
  expect(split.context).toBe(133_523);
});

test("a Codex turn: acpmux takes the cached part out of its input, and its context is its last call's", () => {
  // A Codex turn of 22 calls (its rollout's token_count last_token_usage, added up): input 3,336,595
  // of which 3,021,696 cached; its last call held 170,568 in and 173 out.
  const split = resultTokenSplit(
    {
      inputTokens: 314_899,
      cacheReadTokens: 3_021_696,
      outputTokens: 4_017,
      contextTokens: 170_741,
      inputExcludesCache: true,
    },
    CODEX_CHAT,
  )!;
  expect(uncachedTokens(split)).toBe(314_899);
  expect(cachedTokens(split)).toBe(3_021_696);
  expect(split.calls).toBeUndefined();
  expect(tokenRows(t, "en", split)).toEqual([
    "Output 4K",
    "Input across calls 314.9K\u00a0uncached · 3M\u00a0cached",
    "Context at end 170.7K",
  ]);
});

test("a turn an older acpmux recorded draws no context and no call count", () => {
  const { contextTokens: _context, modelCalls: _calls, inputExcludesCache: _mark, ...older } = CLAUDE_58;
  expect(tokenRows(t, "en", resultTokenSplit(older, CLAUDE_CHAT)!)).toEqual([
    "Output 23.7K",
    "Input across calls 124.7K\u00a0uncached · 4.5M\u00a0cached",
  ]);
});

// The same Codex turn as an older acpmux recorded it: its input whole, the cache's reads in it, and
// no `inputExcludesCache` mark (Codex's ACP usage, copied as it came).
const OLD_CODEX = { inputTokens: 3_336_595, cacheReadTokens: 3_021_696, outputTokens: 4_017 };

test("an older acpmux's Codex turn counts its cached input once: 314.9K uncached, not 3.3M", () => {
  const old = resultTokenSplit(OLD_CODEX, CODEX_CHAT)!;
  expect(uncachedTokens(old)).toBe(314_899);
  expect(cachedTokens(old)).toBe(3_021_696);
  expect(tokenRows(t, "en", old)).toEqual(["Output 4K", "Input across calls 314.9K\u00a0uncached · 3M\u00a0cached"]);
  // Another family's ACP record (Gemini's) is read the same way.
  expect(uncachedTokens(resultTokenSplit(OLD_CODEX, { harness: "gemini", family: "gemini" })!)).toBe(314_899);
  // The marked record of that turn already left the cache out: it is not taken out again.
  const marked = resultTokenSplit({ ...OLD_CODEX, inputTokens: 314_899, inputExcludesCache: true }, CODEX_CHAT)!;
  expect(marked).toEqual(old);
});

test("an older acpmux's Claude turn keeps its input, which was always the fresh part alone", () => {
  const { inputExcludesCache: _mark, ...older } = CLAUDE_58;
  // By the chat's harness, by a Claude leaf family, and with no chat named, by the record's model.
  for (const chat of [CLAUDE_CHAT, { harness: "sr2", family: "claude-sr2" }, { harness: "claude-acp" }])
    expect(uncachedTokens(resultTokenSplit(older, chat)!)).toBe(124_728);
  expect(uncachedTokens(resultTokenSplit({ ...older, model: "claude-opus-4-5" })!)).toBe(124_728);
  // A Codex chat's unmarked record had the cache in its input: that one has it taken out.
  expect(uncachedTokens(resultTokenSplit(OLD_CODEX, CODEX_CHAT)!)).toBe(314_899);
});

test("an unmarked record that names no harness and no Claude model can never count the cache twice", () => {
  // opencode on a Claude model is filed under family "claude" with its own usage: not a Claude.
  for (const chat of [undefined, {}, { harness: "opencode", family: "claude" }])
    expect(uncachedTokens(resultTokenSplit(OLD_CODEX, chat)!)).toBe(314_899);
  expect(uncachedTokens(resultTokenSplit({ ...OLD_CODEX, model: "gpt-5.1-codex" })!)).toBe(314_899);
});

test("the reply time's tooltip: its time, then one count per row", () => {
  expect(replyTimeDetail(t, "en", ["Worked for 1m 16s"], resultTokenSplit(CLAUDE_58))).toBe(
    "Worked for 1m 16s\nOutput 23.7K\nInput across calls 124.7K\u00a0uncached · 4.5M\u00a0cached\nContext at end 125.3K\nModel calls 58",
  );
  expect(replyTimeDetail(t, "en", [undefined, undefined], undefined)).toBeUndefined();
  const row: AcpmuxRow = {
    id: "summary-1",
    kind: "turnSummary",
    version: 1,
    at: Date.UTC(2026, 10, 8, 1, 57),
    status: "completed",
    durationMs: 76_000,
    text: "Done.",
    tokens: resultTokenSplit(CLAUDE_58),
  };
  const markup = renderToStaticMarkup(<TurnFooter row={row} />);
  // The title is the exact time (as a prompt's is); Worked for and the token rows are its detail line.
  expect(markup).toMatch(/<time class="cv-turn-time"[^>]*title="[A-Z][a-z]{2} \d{1,2}, \d{4}, /);
  const title = /<time class="cv-turn-time"[^>]*data-tooltip-detail="([^"]*)"/.exec(markup)?.[1];
  expect(title).toBe(
    "Worked for 1m 16s\nOutput 23.7K\nInput across calls 124.7K\u00a0uncached · 4.5M\u00a0cached\nContext at end 125.3K\nModel calls 58",
  );
  expect(title).not.toContain("4.7M");
});

test("Claude Code behind the cmux router profile, or any profile acpmux says runs it, keeps its input", () => {
  const { inputExcludesCache: _mark, ...older } = CLAUDE_58;
  // The built-in `cmux` profile runs Claude Code over its stream with family `claude`.
  expect(uncachedTokens(resultTokenSplit(older, { harness: "cmux", family: "claude" })!)).toBe(124_728);
  // acpmux's `backgroundsWork` says a chat runs Claude Code, whatever its profile is named.
  const named = { harness: "my-models", family: "claude", backgroundsWork: true };
  expect(uncachedTokens(resultTokenSplit(older, named)!)).toBe(124_728);
  // Neither makes an ACP harness's record fresh: opencode on a Claude model still has it taken out.
  expect(uncachedTokens(resultTokenSplit(OLD_CODEX, { harness: "opencode", family: "claude" })!)).toBe(314_899);
});

test("at a narrow width each count wraps with its words, never apart from them, in every language", () => {
  const split = resultTokenSplit(CLAUDE_58)!;
  const input = (language: string) => tokenRows(translatorFor(language as any), language as any, split)[1]!;
  // The tooltip is plain text, so the count and its words are held by no-break spaces; the line
  // may still break between the label and the counts, and around the " · ".
  expect(input("en")).toBe("Input across calls 124.7K uncached · 4.5M cached");
  expect(input("pl")).toContain(" spoza pamięci podręcznej ·");
  for (const language of ["de", "fr", "it", "ja", "ru", "zh-Hans"])
    for (const part of input(language).split(" · "))
      // From its count on, each part holds no breakable space: the count keeps its words.
      expect(part.slice(part.search(/\d/))).not.toContain(" ");
});

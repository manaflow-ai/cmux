import { describe, expect, test } from "bun:test";
import { decodeEmojiTable, type RawEmojiTable } from "../../icon-picker/emojiData";
import raw from "../../icon-picker/generated/emoji-data.json";
import {
  EMOTICONS,
  closingShortcode,
  emojiMatches,
  emojiTokenIn,
  indexEmoji,
  replaceShortcodes,
  type EmojiTrigger,
} from "./emojiShortcodes";
import { recordUse } from "../../icon-picker/recents";

const data = indexEmoji(decodeEmojiTable(raw as unknown as RawEmojiTable).records);
const rows = (text: string, ...rest: [Parameters<typeof emojiMatches>[2]?, number?]) =>
  emojiMatches(data, at(text) as EmojiTrigger, ...rest);

/// The token `before` (the caret's line up to the caret, as shown) ends, as the composer reads it.
const at = (before: string): EmojiTrigger | undefined => {
  const found = emojiTokenIn(before);
  if (!found) return undefined;
  const { at: start, ...token } = found;
  return { ...token, start };
};

describe("emojiTokenIn", () => {
  test("`:` and two letters at a word start", () => {
    expect(at("hi :te")).toEqual({ start: 3, token: ":te", query: "te", emoticon: false });
    expect(at(":tedd")?.query).toBe("tedd");
    expect(at("hi :t")).toBeUndefined();
    expect(at("hi :")).toBeUndefined();
    // Leo's, on its own line under a list (the composer reads the caret's line, 2026-11-22).
    expect(at(":plead")).toEqual({ start: 0, token: ":plead", query: "plead", emoticon: false });
  });
  test("after an opening bracket or quote, or right after an emoji", () => {
    expect(at("(:smi")).toMatchObject({ start: 1, token: ":smi", query: "smi" });
    expect(at('say ":tad')).toMatchObject({ start: 5, token: ":tad" });
    expect(at("🎉:tad")).toMatchObject({ start: 2, token: ":tad" });
  });
  test("emoticons open with no query, `:DD` with both", () => {
    expect(at("lol :)")).toEqual({ start: 4, token: ":)", query: undefined, emoticon: true });
    expect(at("ha :DD")).toMatchObject({ token: ":DD", query: "dd", emoticon: true });
    expect(at("ok ;)")?.emoticon).toBe(true);
    expect(at("<3")?.emoticon).toBe(true);
    expect(at("(:")?.emoticon).toBe(true);
  });
  test("never in a time, URL, key:value or mid-word", () => {
    expect(at("meet at 10:30")).toBeUndefined();
    expect(at("see https://ex")).toBeUndefined();
    expect(at("see https://x.com:80")).toBeUndefined();
    expect(at("key:value")).toBeUndefined();
    expect(at("foo:bar")).toBeUndefined();
    expect(at("a/:smile")).toBeUndefined();
  });
  test("never into code or an attachment (they reach here masked as U+FFFC)", () => {
    expect(at("run \uFFFC\uFFFC:sm")).toBeUndefined();
    expect(at("\uFFFC:smile")).toBeUndefined();
  });
});

describe("closingShortcode", () => {
  test("the `:` after a known code writes its emoji over the whole `:code`", () => {
    expect(closingShortcode(data, "aw :pleading_face", 0)).toEqual({
      back: 14,
      emoji: "🥺",
      key: "🥺",
      tone: undefined,
    });
    expect(closingShortcode(data, ":+1", 0)?.emoji).toBe("👍");
    expect(closingShortcode(data, ":thumbsup", 0)?.emoji).toBe("👍");
    expect(closingShortcode(data, "🎉:tada", 0)?.back).toBe(5);
  });
  test("an unknown code, a time, a URL or a mid-word colon stay text", () => {
    expect(closingShortcode(data, "aw :notacode", 0)).toBeUndefined();
    expect(closingShortcode(data, "at 10:30", 0)).toBeUndefined();
    expect(closingShortcode(data, "x.com/:tada", 0)).toBeUndefined();
    expect(closingShortcode(data, "key:tada", 0)).toBeUndefined();
    expect(closingShortcode(data, "\uFFFC:tada", 0)).toBeUndefined();
  });
  test("skin tones: the remembered one, Slack's `::skin-tone-N`, and N after a toned emoji", () => {
    expect(closingShortcode(data, ":wave", 3)?.emoji).toBe("👋🏽");
    expect(closingShortcode(data, ":tada", 3)?.emoji).toBe("🎉");
    expect(closingShortcode(data, ":wave::skin-tone-4", 0)).toMatchObject({ back: 18, emoji: "👋🏽", tone: 3 });
    expect(closingShortcode(data, "hi 👋:skin-tone-6", 0)).toMatchObject({ back: 14, emoji: "👋🏿", tone: 5 });
    expect(closingShortcode(data, "hi 👋🏻:skin-tone-1", 0)).toMatchObject({ emoji: "👋", tone: 0 });
    // A glyph with no tones keeps the suffix as text.
    expect(closingShortcode(data, "🎉:skin-tone-3", 0)).toBeUndefined();
  });
});

describe("replaceShortcodes (a paste)", () => {
  test("known codes become emoji; code, URLs and unknown codes stay", () => {
    expect(replaceShortcodes(data, "ship it :tada: `:tada:` :nope:", 0)).toBe("ship it 🎉 `:tada:` :nope:");
    expect(replaceShortcodes(data, "see https://x.com/:tada: now", 0)).toBe("see https://x.com/:tada: now");
    expect(replaceShortcodes(data, "```\n:tada:\n```\n:tada:", 0)).toBe("```\n:tada:\n```\n🎉");
    expect(replaceShortcodes(data, ":tada::tada:", 0)).toBe("🎉🎉");
    expect(replaceShortcodes(data, "at 10:30:45 ok", 0)).toBe("at 10:30:45 ok");
    expect(replaceShortcodes(data, ":wave::skin-tone-3: :wave:", 0)).toBe("👋🏼 👋");
    expect(replaceShortcodes(data, "no colons", 0)).toBe("no colons");
  });
});

describe("emojiMatches", () => {
  test(":tedd lists the teddy bear first", () => {
    expect(rows(":tedd")[0]).toMatchObject({ emoji: "🧸", code: "teddy_bear", matched: 4, matchedAt: 0 });
  });
  test(":DD is a laughing face, never a middle finger", () => {
    const found = rows(":DD");
    expect(found[0]?.emoji).toBe("😆");
    expect(found.map((row) => row.code)).not.toContain("middle_finger");
    expect(found.map((row) => row.code)).not.toContain("fu");
  });
  test("an exact code comes first, then prefixes, then word starts", () => {
    const found = rows(":heart");
    expect(found[0]).toMatchObject({ emoji: "❤️", code: "heart" });
    expect(found[1]!.code.startsWith("heart")).toBe(true);
    const bear = rows(":bear");
    expect(bear[0]!.code).toBe("bear");
    expect(bear.some((row) => row.code === "teddy_bear" || row.code === "polar_bear")).toBe(true);
  });
  test("each emoticon maps to faces the table has", () => {
    for (const [token, codes] of Object.entries(EMOTICONS)) {
      for (const code of codes) expect(data.byCode.has(code), `${token} → ${code}`).toBe(true);
      expect(rows(token).length).toBeGreaterThan(0);
    }
    expect(rows(":)")[0]?.emoji).toBe("🙂");
    expect(rows("<3")[0]?.emoji).toBe("❤️");
    expect(rows(";)")[0]?.emoji).toBe("😉");
  });
  test("a recent pick ranks up, never over an exact code", () => {
    const now = 1_000_000;
    const before = rows(":smi", undefined, now).map((row) => row.emoji);
    const last = before.at(-1)!;
    const prefs = recordUse({ tone: 0, recents: [] }, last, now);
    expect(
      rows(":smi", prefs, now)
        .map((row) => row.emoji)
        .indexOf(last),
    ).toBeLessThan(before.indexOf(last));
    const smile = recordUse({ tone: 0, recents: [] }, "🙂", now);
    expect(rows(":heart", smile, now)[0]?.code).toBe("heart");
  });
  test("at most six rows, one per glyph", () => {
    const found = rows(":sm");
    expect(found.length).toBe(6);
    expect(new Set(found.map((row) => row.emoji)).size).toBe(found.length);
  });
  test("a code with nothing to offer lists nothing", () => {
    expect(rows(":zzqx")).toEqual([]);
  });
  test("Leo's `:plead` lists 🥺 first; `:sob` 😭; a word inside a code (`:joy` in joy_cat) and aliases count", () => {
    expect(rows(":plead")[0]).toMatchObject({ emoji: "🥺", code: "pleading_face" });
    expect(rows(":sob")[0]).toMatchObject({ emoji: "😭", code: "sob" });
    expect(rows(":thumbsu")[0]?.emoji).toBe("👍");
    expect(rows(":cat").some((row) => row.code === "joy_cat")).toBe(true);
  });
  test("a prefix finds its code: `:plead`, `:cry`, `:+1`", () => {
    expect(rows(":plead")[0]?.code).toBe("pleading_face");
    expect(rows(":cry")[0]?.emoji).toBe("😢");
    expect(at("so :+1")).toMatchObject({ token: ":+1" });
    expect(rows(":+1")[0]?.emoji).toBe("👍");
  });
  test("an emoji picked lately comes first for a prefix it matches", () => {
    const now = 1_000_000;
    const before = rows(":smi", undefined, now).map((row) => row.emoji);
    const last = before.at(-1)!;
    const prefs = recordUse({ tone: 0, recents: [] }, last, now);
    expect(rows(":smi", prefs, now)[0]?.emoji).toBe(last);
  });
  test("a half-remembered code finds its emoji by its letters in order (`:thup`)", () => {
    expect(rows(":thup")[0]?.emoji).toBe("👍");
    // Two letters never go loose: too many codes hold them in order.
    expect(rows(":tp").some((row) => row.code === "thumbsup")).toBe(false);
  });
  test("toned emoji list in the remembered tone; the row's key stays the base glyph", () => {
    const found = rows(":wave", { tone: 3, recents: [] });
    expect(found[0]).toMatchObject({ key: "👋", emoji: "👋🏽" });
    expect(rows(":tada", { tone: 3, recents: [] })[0]?.emoji).toBe("🎉");
  });
  test("frequent beats once: a glyph picked often outranks one picked once", () => {
    const now = 1_000_000;
    expect(
      rows(":smile", undefined, now)
        .map((row) => row.emoji)
        .slice(0, 2),
    ).toEqual(["😄", "😃"]);
    const once = recordUse({ tone: 0, recents: [] }, "😃", now);
    let often = recordUse(once, "😸", now - 10);
    often = recordUse(often, "😸", now - 5);
    const order = rows(":smile", often, now).map((row) => row.emoji);
    // The exact code still leads; of the rest, the frequent pick comes first.
    expect(order.slice(0, 3)).toEqual(["😄", "😸", "😃"]);
  });
});

import { describe, expect, test } from "bun:test";
import { decodeEmojiTable, type RawEmojiTable } from "../../icon-picker/emojiData";
import raw from "../../icon-picker/generated/emoji-data.json";
import { EMOTICONS, emojiMatches, emojiTrigger, indexEmoji, type EmojiTrigger } from "./emojiShortcodes";
import { recordUse } from "../../icon-picker/recents";

const data = indexEmoji(decodeEmojiTable(raw as unknown as RawEmojiTable).records);
const at = (text: string) => emojiTrigger(text, text.length);
const rows = (text: string, ...rest: [Parameters<typeof emojiMatches>[2]?, number?]) =>
  emojiMatches(data, at(text) as EmojiTrigger, ...rest);

describe("emojiTrigger", () => {
  test("`:` and two letters at a word start", () => {
    expect(at("hi :te")).toEqual({ start: 3, token: ":te", query: "te", emoticon: false });
    expect(at(":tedd")?.query).toBe("tedd");
    expect(at("hi :t")).toBeUndefined();
    expect(at("hi :")).toBeUndefined();
  });
  test("markdown escapes are undone", () => {
    expect(at("a :teddy\\_b")?.query).toBe("teddy_b");
    expect(at("love &lt;3")?.token).toBe("<3");
    expect(at("love \\<3")?.token).toBe("<3");
  });
  test("emoticons open with no query, `:DD` with both", () => {
    expect(at("lol :)")).toEqual({ start: 4, token: ":)", query: undefined, emoticon: true });
    expect(at("ha :DD")).toMatchObject({ token: ":DD", query: "dd", emoticon: true });
    expect(at("ok ;)")?.emoticon).toBe(true);
    expect(at("<3")?.emoticon).toBe(true);
  });
  test("never in a time, URL, key:value or mid-word", () => {
    expect(at("meet at 10:30")).toBeUndefined();
    expect(at("see https://ex")).toBeUndefined();
    expect(at("key:value")).toBeUndefined();
    expect(at("foo:bar")).toBeUndefined();
  });
  test("never in code", () => {
    expect(at("run `:te")).toBeUndefined();
    expect(at("```\n:smile")).toBeUndefined();
    expect(at("```\nx\n```\n:smile")?.query).toBe("smile");
    expect(at("`x` :smile")?.query).toBe("smile");
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
});

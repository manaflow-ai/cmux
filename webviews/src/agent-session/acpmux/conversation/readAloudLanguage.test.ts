// l10n-allow-file: test fixture sentences in several languages, not shipped UI.
// Read aloud speaks in the message's script when it is not the pane's: a Japanese reply read by an
// English voice is noise. Latin text keeps the pane's language, as its letters cannot name one.
import { expect, test } from "bun:test";
import { spokenLanguage } from "./readAloud";

test("Latin text keeps the pane's language", () => {
  expect(spokenLanguage("Hola, ¿cómo estás?", "en")).toBe("en");
  expect(spokenLanguage("Hola, ¿cómo estás?", undefined)).toBeUndefined();
});

test("another script picks its language", () => {
  expect(spokenLanguage("これはテストです。ファイルを開きます。", "en")).toBe("ja");
  expect(spokenLanguage("테스트 메시지입니다", "en")).toBe("ko");
  expect(spokenLanguage("Это тестовое сообщение", "en")).toBe("ru");
  expect(spokenLanguage("هذه رسالة اختبار", "en-US")).toBe("ar");
  expect(spokenLanguage("นี่คือข้อความทดสอบ", "fr")).toBe("th");
});

test("Han text with kana is Japanese, without it Chinese", () => {
  expect(spokenLanguage("今日は天気がいいので、散歩に行きます", "en")).toBe("ja");
  expect(spokenLanguage("今天天气很好，我们去散步吧", "en")).toBe("zh-CN");
});

test("kanji alone keeps a Japanese or Chinese pane's voice", () => {
  expect(spokenLanguage("確認完了", "ja")).toBe("ja");
  expect(spokenLanguage("確認完了", "ja-JP")).toBe("ja-JP");
  expect(spokenLanguage("确认完成", "zh-Hans")).toBe("zh-Hans");
  // Under another pane language Han is read as Chinese, the likelier voice than an English one.
  expect(spokenLanguage("確認完了", "en")).toBe("zh-CN");
});

test("a stray quoted kana word does not turn a Chinese message Japanese", () => {
  const chinese = "我们昨天讨论了很多关于这个项目的问题，最后决定把那只「ねこ」的图标换掉，然后继续推进后面的工作安排";
  expect(spokenLanguage(chinese, "en")).toBe("zh-CN");
  expect(spokenLanguage(chinese, undefined)).toBe("zh-CN");
  expect(spokenLanguage(chinese, "zh-Hans")).toBe("zh-Hans");
  // Real Japanese has kana throughout, even with a Japanese pane or none.
  expect(spokenLanguage("明日は会議があるので、資料を準備しておきます", "en")).toBe("ja");
});

test("a fallback in the script's own family is kept", () => {
  expect(spokenLanguage("今天天气很好，我们去散步吧", "zh-Hant")).toBe("zh-Hant");
  expect(spokenLanguage("Це тестове повідомлення", "uk")).toBe("uk");
  expect(spokenLanguage("これはテストです。", "ja")).toBe("ja");
});

test("a quoted word in another script does not change the language", () => {
  expect(spokenLanguage("The Japanese word 猫 means cat, and this sentence is otherwise English.", "en")).toBe("en");
});

test("digits and punctuation of a script's block are not its letters", () => {
  expect(spokenLanguage("The result is ١٢٣٤٥٦٧٨٩", "en")).toBe("en");
  expect(spokenLanguage("Version ०१२३४५६७८९ shipped", "en")).toBe("en");
  expect(spokenLanguage("Total ๑๒๓๔๕๖๗", "en")).toBe("en");
  expect(spokenLanguage("هذه رسالة ١٢٣", "en")).toBe("ar");
});

test("the Katakana long-vowel mark counts as Japanese", () => {
  expect(spokenLanguage("コンピューター", "en")).toBe("ja");
});

test("text without letters keeps the fallback", () => {
  expect(spokenLanguage("1234 — 5678", "de")).toBe("de");
});

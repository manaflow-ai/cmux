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

import { describe, expect, test } from "bun:test";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import type { OnboardingFooter } from "./ops";
import { countsLine, keychainLine, keyIntent, primaryLabel, quotedList } from "./text";

const en = createStrings(table, ["en"]);
const de = createStrings(table, ["de"]);
const zero = { bookmarks: 0, history: 0, openTabs: 0, cookies: 0, passwords: 0, searchEngines: 0 };
const footer: OnboardingFooter = {
  primary: "continue",
  primaryEnabled: true,
  skip: "skip",
  showsBack: false,
  backEnabled: true,
  progress: null,
};

describe("counts line", () => {
  test("kinds in order with localized numbers, the search engine named without a count", () => {
    expect(
      countsLine(en, { ...zero, history: 8311, bookmarks: 204, passwords: 41, cookies: 3, searchEngines: 1 }),
    ).toBe("Bookmarks 204 · History 8,311 · Sign-ins 3 · Passwords 41 · Search Engine");
  });
  test("nothing came over is empty, and a missing counts object too", () => {
    expect(countsLine(en, zero)).toBe("");
    expect(countsLine(en, null)).toBe("");
  });
  test("numbers follow the page's language", () => {
    expect(countsLine(de, { ...zero, history: 8311 })).toBe(`${de.t("onboarding.kind.history")} 8.311`);
  });
});

describe("keychain line", () => {
  test("names each item in quotation marks as a list", () => {
    expect(keychainLine(en, ["A Safe Storage", "B Safe Storage"], false)).toBe(
      "Some data is encrypted, so macOS will ask for your computer password to let cmux use “A Safe Storage” and “B Safe Storage” and bring it in securely.",
    );
  });
  test("adds the primary password line when the choice includes Firefox", () => {
    expect(keychainLine(en, ["A Safe Storage"], true)).toEndWith(en.t("onboarding.passwords.firefoxPrimary"));
  });
  test("Firefox alone asks for no Keychain item", () => {
    expect(keychainLine(en, [], true)).toBe(en.t("onboarding.passwords.firefoxOnly"));
  });
  test("quotation marks and list words follow the language", () => {
    expect(quotedList(["A", "B"], "de")).toBe("„A“ und „B“");
    expect(quotedList(["A"], "ja")).toBe("「A」");
  });
});

describe("primary label", () => {
  test("each footer action has its button title", () => {
    expect(primaryLabel(en, "continue")).toBe("Continue");
    expect(primaryLabel(en, "done")).toBe("Done");
    expect(primaryLabel(en, "detecting")).toBe("Looking for browsers…");
    expect(primaryLabel(en, "findBrowsers")).toBe("Find Browsers");
    expect(primaryLabel(en, "import")).toBe("Import");
    expect(primaryLabel(en, "beginImporting")).toBe("Begin Importing");
  });
});

describe("Return and Escape", () => {
  const element = (selector: string | null, extra: Record<string, unknown> = {}) => ({
    tagName: "DIV",
    closest: (query: string) => (selector && query.includes(selector) ? {} : null),
    ...extra,
  });
  test("Return presses the primary; Escape skips", () => {
    expect(keyIntent({ key: "Enter", target: element(null) }, footer)).toBe("next");
    expect(keyIntent({ key: "Escape", target: element(null) }, footer)).toBe("skip");
  });
  test("not a repeat, a modifier, an IME composition or a press already taken", () => {
    expect(keyIntent({ key: "Enter", repeat: true }, footer)).toBeNull();
    expect(keyIntent({ key: "Enter", metaKey: true }, footer)).toBeNull();
    expect(keyIntent({ key: "Enter", isComposing: true }, footer)).toBeNull();
    expect(keyIntent({ key: "Escape", defaultPrevented: true }, footer)).toBeNull();
  });
  test("not while the primary is disabled", () => {
    expect(keyIntent({ key: "Enter", target: element(null) }, { ...footer, primaryEnabled: false })).toBeNull();
  });
  test("a text field, a focused button and an open popup keep Return", () => {
    expect(keyIntent({ key: "Enter", target: element(null, { tagName: "INPUT", type: "text" }) }, footer)).toBeNull();
    expect(keyIntent({ key: "Enter", target: element(null, { tagName: "TEXTAREA" }) }, footer)).toBeNull();
    expect(keyIntent({ key: "Enter", target: element("button") }, footer)).toBeNull();
    expect(keyIntent({ key: "Enter", target: element('[role="menu"]') }, footer)).toBeNull();
    expect(keyIntent({ key: "Escape", target: element('[role="menu"]') }, footer)).toBeNull();
  });
  test("a checkbox does not keep Return", () => {
    expect(keyIntent({ key: "Enter", target: element(null, { tagName: "INPUT", type: "checkbox" }) }, footer)).toBe(
      "next",
    );
  });
});

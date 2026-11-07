// URL display (ported from OmnibarFilePathDisplayTests), text rules, keywords, the TLD typo
// fixup, the http fallback (ported from OmnibarChromeGapsTests) and the effect applier.
import { describe, expect, test } from "bun:test";
import { OmnibarEffectApplier } from "./effect-applier";
import type { OmnibarFieldSurface, OmnibarPopupSurface } from "./effect-applier";
import { fixHostTypo } from "./host-typo-fixup";
import { HTTPSUpgradeFallback, NSURL_ERROR_DOMAIN, NSURLError } from "./https-upgrade-fallback";
import type { BrowserLoadError } from "./https-upgrade-fallback";
import { exactKeyword, keywordSuggestionRow, matchKeyword } from "./keyword";
import { presentation } from "./presentation";
import { clamped, desiredTLDURL, droppedText, inlineCompletion, singleLine } from "./rules";
import { engineSiteURL, SEARCH_ENGINES, searchEngineKeywords, searchURL } from "./search-engine";
import { initialOmnibarState } from "./state";
import { NOT_FOUND } from "./text";
import { row, run, testURL, typed } from "./testing";
import { tabTitle, urlDisplayText, urlEditingText, urlHostRange } from "./url-display";

describe("file paths and addresses (OmnibarFilePathDisplayTests)", () => {
  const home = "/Users/someone";

  test("a file under home shows the tilde form", () => {
    expect(urlDisplayText("file:///Users/someone/fun/notes/README.md", home)).toBe("~/fun/notes/README.md");
  });

  test("a remote desktop tab shows no address", () => {
    const desktop = "cmux://remote-view?host=vm-4a1ca3aa&target=virtual&mode=control&via=cloud-rd";
    expect(urlDisplayText(desktop)).toBe("");
    expect(urlEditingText(desktop)).toBe("");
    expect(urlDisplayText("https://example.com/a")).toBe("example.com/a");
    expect(urlEditingText("https://example.com/a")).toBe("https://example.com/a");
  });

  test("home itself is the tilde", () => {
    expect(urlDisplayText("file:///Users/someone/", home)).toBe("~");
  });

  test("a sibling of home keeps the whole path", () => {
    expect(urlDisplayText("file:///Users/someone2/a.md", home)).toBe("/Users/someone2/a.md");
    expect(urlDisplayText("file:///tmp/a%20b.md", home)).toBe("/tmp/a b.md");
  });

  test("editing keeps the absolute address", () => {
    expect(urlEditingText("file:///Users/someone/fun/README.md")).toBe("file:///Users/someone/fun/README.md");
  });

  test("the bar shows a home file with the tilde", () => {
    const state = initialOmnibarState("file:///Users/someone/fun/README.md", { home });
    expect(presentation(state).text).toBe("~/fun/README.md");
  });
});

describe("compact display", () => {
  test.each([
    ["https://www.example.com/", "example.com"],
    ["https://example.com", "example.com"],
    ["https://www.example.com/a?b=1#c", "example.com/a?b=1#c"],
    ["http://example.com/a", "http://example.com/a"],
    ["https://user:pw@example.com/a", "example.com/a"],
    ["https://www.co.uk/", "co.uk"],
    ["https://www.example/", "www.example"],
    ["https://example.com/caf%C3%A9", "example.com/café"],
    ["https://example.com/100%", "example.com/100%"],
    ["chrome://extensions/", "chrome://extensions"],
    ["chrome://newtab/", ""],
    ["about:blank", ""],
    ["mailto:a@b.c", "mailto:a@b.c"],
  ])("%p shows %p", (url, text) => {
    expect(urlDisplayText(url)).toBe(text);
  });

  test("the host range covers the host in compact and full text", () => {
    expect(urlHostRange("http://example.com/a", "http://example.com/a")).toEqual({ location: 7, length: 11 });
    expect(urlHostRange("[::1]:8080/x", "https://[::1]:8080/x")).toEqual({ location: 0, length: 5 });
    expect(urlHostRange("x", "file:///x")).toBeNull();
  });

  test("tab titles fall back to the host", () => {
    expect(tabTitle({ title: "Page", url: "https://a.com/" })).toBe("Page");
    expect(tabTitle({ url: "https://a.com/x" })).toBe("a.com");
    expect(tabTitle({ url: "about:blank" })).toBeNull();
  });
});

describe("text rules", () => {
  test("inline completion completes the display form or the full URL", () => {
    const github = row("history", "https://github.com/");
    expect(inlineCompletion(github, "Git")).toBe("hub.com");
    expect(inlineCompletion(github, "https://gi")).toBe("thub.com");
    expect(inlineCompletion(github, "git ")).toBeNull();
    expect(inlineCompletion(github, "github.com")).toBeNull();
    expect(inlineCompletion(row("search", "https://github.com/"), "git")).toBeNull();
  });

  test("Control-Enter wraps only a bare host", () => {
    expect(desiredTLDURL(" example ", testURL)).toBe("https://www.example.com");
    expect(desiredTLDURL("localhost:3000", testURL)).toBeNull();
    expect(desiredTLDURL("two words", testURL)).toBeNull();
    expect(desiredTLDURL("a.b", testURL)).toBeNull();
  });

  test("paste and drop cleaning", () => {
    expect(singleLine("a\r\nb\nc")).toBe("a  b c");
    expect(droppedText(" javascript:  javascript:x ")).toBe("x");
  });

  test("clamping keeps a caret a caret", () => {
    expect(clamped({ location: 9, length: 0 }, 4)).toEqual({ location: 4, length: 0 });
    expect(clamped({ location: 2, length: 9 }, 4)).toEqual({ location: 2, length: 2 });
    expect(clamped({ location: NOT_FOUND, length: 0 }, 4)).toEqual({ location: 4, length: 0 });
  });
});

describe("keywords and engines", () => {
  const keywords = searchEngineKeywords(SEARCH_ENGINES.google);

  test("the engine keywords are their search hosts", () => {
    expect(keywords.map((k) => k.keyword)).toEqual([
      "google.com",
      "duckduckgo.com",
      "bing.com",
      "search.brave.com",
      "kagi.com",
      "youtube.com",
      "wikipedia.org",
      "github.com",
    ]);
  });

  test("matching a keyword and a space, and an exact keyword or its site", () => {
    expect(matchKeyword("YouTube.com cats", keywords)?.rest).toBe("cats");
    expect(matchKeyword("youtube.comx", keywords)).toBeNull();
    expect(exactKeyword("https://www.youtube.com/", keywords)?.searchEngine?.id).toBe("youtube");
  });

  test("search URLs escape everything but unreserved characters", () => {
    expect(searchURL(SEARCH_ENGINES.google, " a&b=c (d)! ")).toBe(
      "https://www.google.com/search?q=a%26b%3Dc%20%28d%29%21",
    );
    expect(searchURL(SEARCH_ENGINES.google, "  ")).toBeNull();
    expect(engineSiteURL(SEARCH_ENGINES.duckDuckGo)).toBe("https://duckduckgo.com/");
  });

  test("an extension's row carries its content", () => {
    const suggestion = keywordSuggestionRow("ext1", "a b", "Desc", 2);
    expect(suggestion).toMatchObject({ kind: "keyword", title: "Desc", detail: "a b", content: "a b", score: 998 });
    expect(suggestion.url).toBe("cmux-omnibox://ext1/a%20b");
  });
});

describe("TLD typo fixup", () => {
  test.each([
    ["example.con", "example.com", "example.con"],
    ["https://Example.CMO:8080/a?b#c", "https://Example.com:8080/a?b#c", "example.cmo"],
    ["shop.ogr/x", "shop.org/x", "shop.ogr"],
  ])("%p becomes %p", (text, fixed, typedHost) => {
    expect(fixHostTypo(text)).toEqual({ text: fixed, typedHost });
  });

  test.each(["example.com", "localhost", "a@b.con", "ftp://a.con", "[::1].con", "a.con:x", "a..con", "a b.con"])(
    "%p is left alone",
    (text) => {
      expect(fixHostTypo(text)).toBeNull();
    },
  );

  test("a delegated top-level domain is never fixed", () => {
    expect(fixHostTypo("example.con", (label) => label === "con")).toBeNull();
  });
});

describe("http fallback (OmnibarChromeGapsTests)", () => {
  const https = "https://example.com";
  const failing = (code: number) => ({
    isLoading: false,
    loadError: { domain: NSURL_ERROR_DOMAIN, code, message: "", failingURL: https } satisfies BrowserLoadError,
  });

  test("a refused upgrade falls back to http once", () => {
    const fallback = new HTTPSUpgradeFallback();
    fallback.expect(https);
    expect(fallback.observe(failing(NSURLError.cannotConnectToHost))).toBe("http://example.com");
    expect(fallback.pending).toBeNull();

    fallback.expect(https);
    expect(fallback.observe(failing(NSURLError.cannotFindHost))).toBeNull();

    fallback.expect(https);
    expect(fallback.observe({ isLoading: true, loadError: null })).toBeNull();
    expect(fallback.observe({ isLoading: false, loadError: null })).toBeNull();
    expect(fallback.pending).toBeNull();
  });

  test("an earlier error does not count; port 443 goes away", () => {
    const fallback = new HTTPSUpgradeFallback();
    const earlier = failing(NSURLError.timedOut).loadError;
    fallback.expect(https, earlier);
    expect(fallback.observe({ isLoading: false, loadError: earlier })).toBeNull();
    fallback.expect("https://example.com:443/a/");
    const error = { domain: "net", code: -102, message: "", failingURL: "https://example.com:443/a" };
    expect(fallback.observe({ isLoading: false, loadError: error })).toBe("http://example.com/a/");
  });

  test("Chromium errors that fall back", () => {
    const error = (code: number): BrowserLoadError => ({ domain: "net", code, message: "" });
    expect(HTTPSUpgradeFallback.fallsBack(error(-102))).toBe(true);
    expect(HTTPSUpgradeFallback.fallsBack(error(-107))).toBe(true);
    expect(HTTPSUpgradeFallback.fallsBack(error(-202))).toBe(true);
    expect(HTTPSUpgradeFallback.fallsBack(error(-105))).toBe(false);
    expect(HTTPSUpgradeFallback.fallsBack(error(-106))).toBe(false);
  });
});

describe("effect applier", () => {
  type FakeField = { -readonly [K in keyof OmnibarFieldSurface]: OmnibarFieldSurface[K] } & { writes: string[] };

  function surfaces() {
    const field: FakeField = {
      isFieldEditorActive: true,
      currentText: "",
      currentSelection: { location: 0, length: 0 },
      hasMarkedText: false,
      writes: [],
      write(text) {
        field.writes.push(text);
        field.currentText = text;
      },
      select(range) {
        field.currentSelection = range;
      },
    };
    const shown: string[] = [];
    const popup: OmnibarPopupSurface = {
      showRows: (rows) => shown.push(`show ${rows.length}`),
      highlightRow: (row) => shown.push(`highlight ${row}`),
      dismissRows: () => shown.push("dismiss"),
    };
    return { field, popup, shown };
  }

  test("a keystroke the field already holds is never written back", () => {
    const { field, popup } = surfaces();
    const applier = new OmnibarEffectApplier(field, popup);
    let state = run(initialOmnibarState(), [{ type: "focusGained", source: "keyboard" }]).state;
    applier.apply(presentation(state));
    const before = applier.textWrites;
    for (const input of typed("abc", "", false)) {
      if (input.type === "fieldChanged") {
        field.currentText = input.field.text;
        field.currentSelection = input.field.selection;
      }
      state = run(state, [input]).state;
      applier.apply(presentation(state));
    }
    expect(applier.textWrites).toBe(before);
  });

  test("nothing is written while composing", () => {
    const { field, popup } = surfaces();
    const applier = new OmnibarEffectApplier(field, popup);
    field.hasMarkedText = true;
    applier.apply(presentation(initialOmnibarState("https://a.com/")));
    expect(field.writes).toEqual([]);
  });
});

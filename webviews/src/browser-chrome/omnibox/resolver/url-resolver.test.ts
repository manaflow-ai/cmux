import { describe, expect, test } from "bun:test";
import { createOmniboxResolver } from "./omnibox-resolver";
import { containsPairingLink, createURLResolver, isLoopback, isNonUniqueHost, splitHostAndPort } from "./url-resolver";

const url = createURLResolver({ homeDirectory: "/Users/me" });

describe("OmnibarChromeParityTests", () => {
  test.each([
    ["192.168.1.20:3000", "http://192.168.1.20:3000"],
    ["10.0.0.5", "http://10.0.0.5"],
    ["100.89.225.106:18765/status", "http://100.89.225.106:18765/status"],
    ["172.16.4.2/admin", "http://172.16.4.2/admin"],
    ["devbox:8080", "http://devbox:8080"],
    ["devbox/", "http://devbox/"],
    ["router/setup", "http://router/setup"],
    ["nas.local", "http://nas.local"],
    ["grafana.internal:3000/d/abc", "http://grafana.internal:3000/d/abc"],
    ["[fd00::1]:8080", "http://[fd00::1]:8080"],
  ])("intranetAddressesLoadOverHTTP %s", (text, expected) => {
    expect(url(text)).toBe(expected);
  });

  test("publicHostsAndSearchesAreUnchanged", () => {
    expect(url("example.com")).toBe("https://example.com");
    expect(url("8.8.8.8")).toBe("https://8.8.8.8");
    expect(url("localhost:3000")).toBe("http://localhost:3000");
    expect(url("devbox")).toBeNull();
    expect(url("swift testing")).toBeNull();
  });

  test("onlyCmuxAppPagesLoadFromTheCmuxScheme", () => {
    expect(url("cmux://stashed")).toBe("cmux://stashed");
    expect(url("CMUX://Stashed/?q=1")).toBe("cmux://stashed");
    expect(url("cmux://tab/tab_0123")).toBeNull();
    expect(url("cmux:stashed")).toBeNull();
  });
});

describe("OmnibarSchemeURLWithSpacesTests", () => {
  test.each([
    ["https://www.google.com/search?q=hello world", "https://www.google.com/search?q=hello%20world"],
    ["http://localhost:3000/a b/c", "http://localhost:3000/a%20b/c"],
    ["file:///Users/me/My Notes.html", "file:///Users/me/My%20Notes.html"],
    ["https://example.com/docs#a section", "https://example.com/docs#a%20section"],
  ])("aSchemeURLWithASpaceAfterItsHostLoads %s", (input, expected) => {
    expect(url(input)).toBe(expected);
  });

  test.each(["https://exa mple.com/", "http://foo bar", "https: is a protocol", "swift testing", "example.com/a b"])(
    "otherTextWithSpacesStillSearches %s",
    (input) => {
      expect(url(input)).toBeNull();
    },
  );
});

describe("MacScreenAddressTests", () => {
  test.each([
    "cmux-vnc://pair?signal=https://s.example&room=00112233445566778899aabbccddeeff&secret=abcdefghijklmnopqrstuvwxyzABCDEF0123&name=Mac",
    "cmux://mac-screen",
    "cmux://mac-screen?device=6F9619FF-8B86-D011-B42D-00C04FC964FF",
  ])("macScreenAddressesNeverSearch %s", (text) => {
    expect(url(text)).toBe(text);
  });

  test.each(["cmux-vnc://other", "cmux://history-elsewhere", "javascript:alert(1)"])(
    "otherSchemesStillSearch %s",
    (text) => {
      expect(url(text)).toBeNull();
    },
  );

  test("containsPairingLink", () => {
    expect(containsPairingLink("  CMUX-VNC://pair?room=r&secret=s  ")).toBe(true);
    expect(containsPairingLink("cmux-vnc:pair?room=r&secret=s")).toBe(true);
    expect(containsPairingLink("connect to cmux-vnc://pair?room=r&secret=s please")).toBe(true);
    expect(containsPairingLink("cmux-vnc://other cmux-vnc:x")).toBe(false);
  });
});

describe("BrowserURLResolver rules", () => {
  test("wrapped pastes load only when the break follows the host", () => {
    expect(url("https://example.com/very/\nlong/path")).toBe("https://example.com/very/long/path");
    expect(url("example.com/a\n\tb")).toBe("https://example.com/ab");
    expect(url("example.\ncom")).toBeNull();
    expect(url("https://exa\nmple.com/")).toBeNull();
  });

  test("explicit schemes", () => {
    expect(url("HTTPS://Example.com/a")).toBe("HTTPS://Example.com/a");
    expect(url("http://")).toBeNull();
    expect(url("https://example.com/a|b")).toBe("https://example.com/a%7Cb");
    expect(url("about:blank")).toBe("about:blank");
    expect(url("ABOUT:BLANK")).toBe("about:blank");
    expect(url("data:text/html,hi")).toBeNull();
    expect(url("mailto:me@example.com")).toBeNull();
    expect(url("file:///tmp/x")).toBe("file:///tmp/x");
    expect(url("file:relative")).toBeNull();
  });

  test("files", () => {
    expect(url("/tmp/My Notes.txt")).toBe("file:///tmp/My%20Notes.txt");
    expect(url("~")).toBe("file:///Users/me/");
    expect(url("~/code/a#b")).toBe("file:///Users/me/code/a%23b");
    expect(createURLResolver()("~/x")).toBeNull();
  });

  test("Chromium pages: a WebKit tab takes only cmux's own", () => {
    expect(url("chrome://history")).toBe("chrome://history/");
    expect(url("about:bookmarks")).toBe("chrome://bookmarks/");
    expect(url("chrome://settings")).toBe("chrome://settings/");
    expect(url("chrome://settings/passwords")).toBe("chrome://settings/passwords");
    expect(url("chrome://settings/cookies")).toBeNull();
    expect(url("chrome://extensions")).toBeNull();
    const chromium = createURLResolver({ allowsChromiumSchemes: true });
    expect(chromium("CHROME://Extensions?id=x")).toBe("chrome://extensions/?id=x");
    expect(chromium("chrome:version")).toBe("chrome://version/");
    expect(chromium("about:flags")).toBe("chrome://flags/");
    expect(chromium("about:srcdoc")).toBeNull();
    expect(chromium("chrome-extension://abc/popup.html")).toBe("chrome-extension://abc/popup.html");
    expect(chromium("chrome://user@host/")).toBeNull();
  });

  test("scheme-less text", () => {
    expect(url("user@example.com")).toBeNull();
    expect(url("example.com:8080/x")).toBe("https://example.com:8080/x");
    expect(url("example.c")).toBeNull();
    expect(url("example.xn--p1ai")).toBe("https://example.xn--p1ai");
    expect(url("app.localhost")).toBe("http://app.localhost");
    expect(url("127.0.0.1:8000")).toBe("http://127.0.0.1:8000");
    expect(url("[2001:db8::1]")).toBe("https://[2001:db8::1]");
    expect(url("1234")).toBeNull();
    expect(url("devbox:99999")).toBeNull();
    expect(url("?q")).toBeNull();
  });

  test("host helpers", () => {
    expect(splitHostAndPort("Example.com:80")).toEqual({ host: "example.com", hasPort: true });
    expect(splitHostAndPort("[::1]:x")).toEqual({ host: "", hasPort: false });
    expect(isLoopback("127.1.2.3")).toBe(true);
    expect(isLoopback("127.0.0.256")).toBe(false);
    expect(isNonUniqueHost("100.64.0.1")).toBe(true);
    expect(isNonUniqueHost("100.128.0.1")).toBe(false);
    expect(isNonUniqueHost("fe80::1")).toBe(true);
    expect(isNonUniqueHost("printer.home.arpa")).toBe(true);
  });
});

describe("Unicode URLs (URLComponents(string:) on macOS 14+)", () => {
  const resolver = createOmniboxResolver();

  test("an explicit URL with a Unicode path loads percent-encoded", () => {
    expect(url("https://example.com/café")).toBe("https://example.com/caf%C3%A9");
    expect(url("https://example.com/パス?q=日本#節")).toBe(
      "https://example.com/%E3%83%91%E3%82%B9?q=%E6%97%A5%E6%9C%AC#%E7%AF%80",
    );
  });

  test("an explicit URL with an IDN host loads in punycode", () => {
    expect(url("https://例え.jp/")).toBe("https://xn--r8jz45g.jp/");
    expect(url("http://Bücher.example:8080/a")).toBe("http://xn--bcher-kva.example:8080/a");
  });

  test("a scheme-less IDN host loads over https", () => {
    expect(url("例え.jp")).toBe("https://xn--r8jz45g.jp");
    expect(url("例え.jp/パス")).toBe("https://xn--r8jz45g.jp/%E3%83%91%E3%82%B9");
    expect(url("例え.みんな")).toBe("https://xn--r8jz45g.xn--q9jyb4c");
  });

  test("a scheme-less ASCII host with a Unicode path loads", () => {
    expect(url("example.com/café")).toBe("https://example.com/caf%C3%A9");
    expect(resolver.destination("example.com/café")).toEqual({ kind: "url", url: "https://example.com/caf%C3%A9" });
  });

  test("Unicode phrases and single words still search", () => {
    expect(url("café au lait")).toBeNull();
    expect(url("café")).toBeNull();
    expect(url("例え")).toBeNull();
    expect(resolver.destination("café au lait")?.kind).toBe("search");
  });
});

// Each row is what `URLComponents(string:)` answered (`components.url`), run against Foundation.
describe("invalid ASCII characters (URLComponents(string:) on macOS 14+)", () => {
  test.each([
    ["https://example.com/a|b", "https://example.com/a%7Cb"],
    ["http://localhost:3000/?filter[status]=open", "http://localhost:3000/?filter%5Bstatus%5D=open"],
    ["https://example.com/a^b{c}", "https://example.com/a%5Eb%7Bc%7D"],
    ["https://example.com/%zz", "https://example.com/%25zz"],
    ["https://example.com/a\\b", "https://example.com/a%5Cb"],
    ["https://example.com/#a#b", "https://example.com/#a%23b"],
  ])("%s loads as %s", (text, expected) => {
    expect(url(text)).toBe(expected);
  });

  test("Paste and Go navigates such an address instead of searching", () => {
    expect(createOmniboxResolver().destination("https://example.com/a|b")).toEqual({
      kind: "url",
      url: "https://example.com/a%7Cb",
    });
  });
});

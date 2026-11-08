import { describe, expect, test } from "bun:test";
import { HostTypoMemory } from "../host-typo-fixup";
import { SEARCH_ENGINES, searchURL } from "../search-engine";
import { hasFocus, initialOmnibarState } from "../state";
import { commits, key, run, typed } from "../testing";
import { intranetCandidate, IntranetHostMemory } from "./intranet";
import { createOmniboxResolver } from "./omnibox-resolver";
import { isTopLevelDomain, topLevelDomains, TOP_LEVEL_DOMAINS_VERSION } from "./top-level-domains.generated";

describe("OmnibarChromeParityTests", () => {
  test.each([
    ["example", "https://www.example.com"],
    ["google/maps", "https://www.google.com/maps"],
    ["www.example", "https://www.example.com"],
  ])("controlEnterAddsWWWAndCom %s", (text, expected) => {
    const step = run(
      initialOmnibarState(),
      [...typed(text), key({ kind: "enterAddingTLD", disposition: "currentTab" })],
      createOmniboxResolver(),
    );
    expect(commits(step.effects)).toEqual([expected]);
    expect(hasFocus(step.state)).toBe(false);
  });

  test("controlEnterLeavesAFullHostAlone", () => {
    const step = run(
      initialOmnibarState(),
      [...typed("example.org"), key({ kind: "enterAddingTLD", disposition: "currentTab" })],
      createOmniboxResolver(),
    );
    expect(commits(step.effects)).toEqual(["https://example.org"]);
  });

  test("aLeadingQuestionMarkForcesASearch", () => {
    const destination = createOmniboxResolver().destination("?example.com");
    expect(destination?.kind).toBe("search");
    expect(destination?.kind === "search" && destination.query).toBe("example.com");
  });
});

describe("IntranetLinkRowsTests", () => {
  const resolver = createOmniboxResolver();

  test("enterOnAGoLinkLoadsIt", () => {
    expect(resolver.destination("go/gday")).toEqual({ kind: "url", url: "http://go/gday" });
  });

  test("aGoLinkLeadsWithTheAddressAndOffersTheSearch", () => {
    expect(resolver.intranetSearchAlternative("go/gday")).toEqual({
      query: "go/gday",
      url: searchURL(resolver.searchEngine, "go/gday") as string,
    });
  });

  test.each(["wiki/Onboarding", "devbox:8080", "jira/"])("otherSingleLabelAddressesOfferTheSearchToo %s", (text) => {
    expect(resolver.destination(text)?.kind).toBe("url");
    expect(resolver.intranetSearchAlternative(text)).not.toBeNull();
  });

  test.each(["github.com", "localhost:3000", "nas.local", "192.168.1.10"])("otherAddressesKeepOneRow %s", (text) => {
    expect(resolver.destination(text)?.kind).toBe("url");
    expect(resolver.intranetSearchAlternative(text)).toBeNull();
  });
});

describe("IntranetHostProbeTests", () => {
  test.each([
    ["wiki", "wiki"],
    ["Go", "go"],
    ["jira-prod", "jira-prod"],
  ])("candidates %s", (text, expected) => {
    expect(intranetCandidate(text)).toBe(expected);
  });

  test.each(["go/gday", "two words", "1234", "x", "-go", "example.com", "wiki?", "日本"])(
    "notCandidates %s",
    (text) => {
      expect(intranetCandidate(text)).toBeNull();
    },
  );

  test("theOmnibarLoadsABareWordTheProbeFound", () => {
    const intranetHosts = new IntranetHostMemory(["wiki"]);
    const resolver = createOmniboxResolver({ intranetHosts });
    expect(resolver.destination("Wiki")).toEqual({ kind: "url", url: "http://wiki/" });
    expect(resolver.intranetSearchAlternative("wiki")?.query).toBe("wiki");
    intranetHosts.record("WIKI", false);
    expect(resolver.destination("wiki")?.kind).toBe("search");
  });

  test("withoutAnAnswerABareWordSearches", () => {
    expect(createOmniboxResolver().destination("wiki")).toEqual({
      kind: "search",
      query: "wiki",
      url: "https://www.google.com/search?q=wiki",
    });
  });
});

describe("destination", () => {
  test("search engine and the forced query", () => {
    const resolver = createOmniboxResolver({ searchEngine: SEARCH_ENGINES.duckDuckGo });
    expect(resolver.destination("  swift testing \n")).toEqual({
      kind: "search",
      query: "swift testing",
      url: "https://duckduckgo.com/?q=swift%20testing",
    });
    expect(resolver.destination("?")).toBeNull();
    expect(resolver.destination("   ")).toBeNull();
    expect(resolver.destination("? a b ")?.kind).toBe("search");
  });
});

describe("host typos", () => {
  test("a TLD typo is fixed once per typed host", () => {
    const memory = new HostTypoMemory();
    const resolver = createOmniboxResolver({ hostTypoMemory: memory });
    expect(resolver.typoFixedURL("example.con/a")).toEqual({ url: "https://example.com/a", typedHost: "example.con" });
    expect(resolver.commitTypoFix("Example.CON")).toBe("https://Example.com");
    expect(memory.allowsFix("example.con")).toBe(false);
    expect(resolver.typoFixedURL("example.con")).toBeNull();
    expect(resolver.typoFixedURL("example.com")).toBeNull();
    expect(resolver.typoFixedURL("ftp://example.con")).toBeNull();
  });

  test("the IANA list the build makes from the Swift resource answers top-level domains", () => {
    expect(TOP_LEVEL_DOMAINS_VERSION).not.toBe("");
    expect(topLevelDomains().size).toBeGreaterThan(1000);
    expect(isTopLevelDomain("COM")).toBe(true);
    expect(isTopLevelDomain("xn--p1ai")).toBe(true);
    expect(isTopLevelDomain("con")).toBe(false);
  });
});

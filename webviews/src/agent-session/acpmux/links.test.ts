import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { FALLBACK_LINK_SCHEME, linkScheme, scrollToTurn, sessionLink, setLinkScheme } from "./links";

afterEach(() => setLinkScheme(undefined));

test("session links use the scheme the host hands over", () => {
  setLinkScheme("cmux-dev-mytag");
  expect(linkScheme()).toBe("cmux-dev-mytag");
  expect(sessionLink("sess-01.ab_c")).toBe("cmux-dev-mytag://session/sess-01.ab_c");
  expect(sessionLink("s1", "turn-7")).toBe("cmux-dev-mytag://session/s1#turn-turn-7");
});

test("without a scheme from the host there is no link, except the mock page's fallback", () => {
  setLinkScheme(undefined);
  expect(linkScheme()).toBeUndefined();
  expect(sessionLink("s1")).toBeUndefined();
  setLinkScheme(42);
  expect(sessionLink("s1")).toBeUndefined();
  setLinkScheme("not a scheme");
  expect(sessionLink("s1")).toBeUndefined();
  setLinkScheme(undefined, FALLBACK_LINK_SCHEME);
  expect(sessionLink("s1")).toBe("cmux://session/s1");
  setLinkScheme("cmux-dev", FALLBACK_LINK_SCHEME);
  expect(sessionLink("s1")).toBe("cmux-dev://session/s1");
});

test("ids a link cannot carry give no link", () => {
  setLinkScheme("cmux");
  for (const id of ["", "a/b", "has space", "a#b", "x".repeat(201)]) expect(sessionLink(id)).toBeUndefined();
  expect(sessionLink("s1", "")).toBeUndefined();
  expect(sessionLink("s1", "t/1")).toBeUndefined();
});

test("revealing a turn scrolls to its row, and is a no-op without one", () => {
  const { document } = new JSDOM(
    `<div><div data-turn-id="t-1"></div><div data-turn-id='a"b'></div><div data-turn-id="t-2"></div></div>`,
  ).window;
  const scrolled: string[] = [];
  for (const row of document.querySelectorAll<HTMLElement>("[data-turn-id]"))
    row.scrollIntoView = () => scrolled.push(row.dataset.turnId ?? "");
  expect(scrollToTurn("t-2", document)).toBe(true);
  expect(scrollToTurn('a"b', document)).toBe(true);
  expect(scrollToTurn("missing", document)).toBe(false);
  expect(scrolled).toEqual(["t-2", 'a"b']);
});

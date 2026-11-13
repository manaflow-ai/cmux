import { describe, expect, test } from "bun:test";
import { spacedAfterDeeplink } from "./deeplinks";

const WORKSPACE = "cmux-nightly://workspace/ws_81e941825bd898c341c7809813e9c17f";

describe("spacedAfterDeeplink", () => {
  test("a pasted link at the line's end gets a space, so the next key starts a word", () => {
    expect(spacedAfterDeeplink(WORKSPACE, "")).toBe(`${WORKSPACE} `);
    expect(spacedAfterDeeplink(`see ${WORKSPACE}`, "")).toBe(`see ${WORKSPACE} `);
    expect(spacedAfterDeeplink("https://cmux.com/deeplink/agent?session=s1", "")).toBe(
      "https://cmux.com/deeplink/agent?session=s1 ",
    );
  });

  test("a link pasted before a word is kept apart from it", () => {
    expect(spacedAfterDeeplink(WORKSPACE, "a")).toBe(`${WORKSPACE} `);
  });

  test("no second space when one already follows", () => {
    expect(spacedAfterDeeplink(WORKSPACE, " ")).toBe(WORKSPACE);
    expect(spacedAfterDeeplink(WORKSPACE, "\n")).toBe(WORKSPACE);
    expect(spacedAfterDeeplink(`${WORKSPACE} `, "")).toBe(`${WORKSPACE} `);
  });

  test("text that does not end in a link is pasted as copied", () => {
    expect(spacedAfterDeeplink(`${WORKSPACE} is the coordinator`, "")).toBe(`${WORKSPACE} is the coordinator`);
    expect(spacedAfterDeeplink(`${WORKSPACE}.`, "")).toBe(`${WORKSPACE}.`);
    expect(spacedAfterDeeplink("https://example.com/page", "")).toBe("https://example.com/page");
    expect(spacedAfterDeeplink("https://example.com/?next=cmux://session/s1", "")).toBe(
      "https://example.com/?next=cmux://session/s1",
    );
  });
});

describe("spacedAfterDeeplink, a paste into a link already in the draft", () => {
  test("a link begun before the paste is not split", () => {
    // The draft `cmux://workspace/ws_abc`, `123` pasted after `ws_`: the text before the caret.
    expect(spacedAfterDeeplink("cmux://workspace/ws_123", "a", "cmux://workspace/ws_".length)).toBe(
      "cmux://workspace/ws_123",
    );
  });

  test("a link the paste begins gets the space after text typed before it", () => {
    expect(spacedAfterDeeplink(`see ${WORKSPACE}`, "", "see ".length)).toBe(`see ${WORKSPACE} `);
  });
});

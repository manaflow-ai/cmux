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

describe("spacedAfterDeeplink, every link the draft draws as a chip", () => {
  // Every kind `deeplinks` finds (replyHref.ts `appHref`, and the web deeplink), in every build's
  // scheme: the space keys off the same finder the chips do, so a new kind is covered with it.
  const CHIP_LINKS = [
    "cmux://workspace/ws_81e941825bd898c341c7809813e9c17f",
    "cmux-nightly://workspace/ws_81e941825bd898c341c7809813e9c17f",
    "cmux-dev://workspace/ws_1",
    "cmux-dev-my-tag://workspace/ws_1",
    "cmux-nightly://pane/p_1",
    "cmux-nightly://tab/t_1",
    "cmux-nightly://session/s_1",
    "cmux-nightly://chief/c_1",
    "cmux-nightly://group/g_1",
    "cmux-nightly://workspace/ws_1?pane=p_2#focus",
    "cmux-nightly://agent/claude/0198a7b2-1c3d-7e4f-8a9b-0c1d2e3f4a5b",
    "cmux://agent/codex/sess_42?turn=3",
    "https://cmux.com/deeplink/workspace?id=ws_1",
    "https://www.cmux.com/ja/deeplink/agent?session=s1",
  ];

  for (const link of CHIP_LINKS) {
    test(`${link}: a space after it, none when one follows, none mid-paste`, () => {
      expect(spacedAfterDeeplink(link, "")).toBe(`${link} `);
      expect(spacedAfterDeeplink(link, "a")).toBe(`${link} `);
      expect(spacedAfterDeeplink(link, " ")).toBe(link);
      expect(spacedAfterDeeplink(`${link} `, "")).toBe(`${link} `);
      expect(spacedAfterDeeplink(`see ${link} and more`, "")).toBe(`see ${link} and more`);
    });
  }

  test("URLs that never become a chip are pasted as copied", () => {
    for (const plain of [
      "https://example.com/workspace/ws_1",
      "http://cmux.com/deeplink/workspace?id=ws_1",
      "https://cmux.com/docs",
      "cmux-nightly://unknown/thing",
      "file:///Users/you/notes.md",
    ])
      expect(spacedAfterDeeplink(plain, "")).toBe(plain);
  });
});

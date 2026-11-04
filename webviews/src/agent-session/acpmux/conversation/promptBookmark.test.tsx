// A prompt's hover row carries the rail's bookmark (Leo, 2026-11-04: "we have the chatgpt bookmarks
// available for user prompts but we dont have a bookmark button there i think we ought to"): the
// same mark the thread minimap shows, on every prompt acpmux has logged.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { bookmarksHeard } from "../threadMinimap/bookmarks";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { BookmarkButton } from "./MessageActions";
import { UserBubble } from "./UserBubble";

const prompt = (id: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "user", text: "hello" }) as AcpmuxRow;

const bubble = (session: string, id: string) =>
  renderToStaticMarkup(
    <PromptMarksSession.Provider value={session}>
      <UserBubble row={prompt(id)} text="hello" />
    </PromptMarksSession.Provider>,
  );

test("a logged prompt's action row has a bookmark button", () => {
  const html = bubble("bookmark-row-a", "user-7");
  expect(html).toContain("cv-message-bookmark");
  expect(html).toMatch(/cv-message-bookmark"[^>]*aria-pressed="false"/);
  // The row's Copy comes before it, inside the prompt's action row.
  expect(html.indexOf("cv-user__actions")).toBeLessThan(html.indexOf("cv-message-bookmark"));
});

test("the button shows the rail's mark", () => {
  bookmarksHeard("bookmark-row-b", [7]);
  const html = renderToStaticMarkup(
    <PromptMarksSession.Provider value="bookmark-row-b">
      <BookmarkButton rowId="user-7" />
      <BookmarkButton rowId="user-8" />
    </PromptMarksSession.Provider>,
  );
  const pressed = [...html.matchAll(/aria-pressed="(true|false)"/g)].map((match) => match[1]);
  expect(pressed).toEqual(["true", "false"]);
});

test("no bookmark on a prompt acpmux has not logged, or in a subagent's view", () => {
  expect(bubble("bookmark-row-c", "local-1")).not.toContain("cv-message-bookmark");
  expect(bubble("bookmark-row-c:subagent:x", "user-7")).not.toContain("cv-message-bookmark");
});

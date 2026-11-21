// l10n-allow-file: test fixtures.
// Leo 2026-11-18: New Tab sorted every chat, closed ones included, to show 3 to 6 recent ones, and
// built a card for each of about 2,500 child chats, behind a Minimal page that draws no chats: "We
// literally don't even have that as a visible option at all anymore".
import { expect, test } from "bun:test";
import * as screenModel from "../src/agent-session/acpmux/newtab/screenModel";
import { screenSections } from "../src/agent-session/acpmux/newtab/templates";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const entry = (id: string, updatedAt: number, spawnedBy?: string): AcpmuxSessionEntry => ({
  sessionId: id,
  displayTitle: id,
  updatedAt,
  ...(spawnedBy ? { spawnedBy } : {}),
});

// Every read of a chat (or of one field, `only`) counts, so a page that only skips the output
// still fails.
function counted(
  sessions: AcpmuxSessionEntry[],
  only?: string,
): { sessions: AcpmuxSessionEntry[]; reads: () => number } {
  let reads = 0;
  const wrapped = sessions.map(
    (session) =>
      new Proxy(session, {
        get(target, key, receiver) {
          if (only === undefined || key === only) reads += 1;
          return Reflect.get(target, key, receiver);
        },
      }),
  );
  return { sessions: wrapped, reads: () => reads };
}

test("Minimal, the default page, lists no chats and reads none", () => {
  const minimal = screenSections("minimal");
  expect(minimal.chats).toBe("none");
  const { sessions, reads } = counted([entry("parent", 1), entry("child", 2, "parent")]);
  expect(screenModel.pageChatCards(minimal, sessions, 10, (key) => key, [])).toEqual([]);
  expect(reads()).toBe(0);
});

test("only the shown parents' children get a card", () => {
  // 5 shown parents, and 2,500 children under one parent past the cut.
  const parents = Array.from({ length: 6 }, (_, index) => entry(`p${index}`, 100 - index));
  // A card reads its chat's `preview`; nothing else on the page does.
  const hidden = counted(
    Array.from({ length: 2500 }, (_, index) => entry(`c${index}`, 1, "p5")),
    "preview",
  );
  const shownChild = entry("shown-child", 50, "p0");
  const cards = screenModel.pageChatCards(
    screenSections("default"),
    [...parents, ...hidden.sessions, shownChild],
    1000,
    (key) => key,
    [],
  );
  expect(hidden.reads()).toBe(0);
  expect(cards.map((card) => card.sessionId)).toEqual(["p0", "p1", "p2", "p3", "p4"]);
  expect(cards[0]?.children?.map((card) => card.sessionId)).toEqual(["shown-child"]);
  expect(cards.slice(1).every((card) => card.children === undefined)).toBe(true);
});

// l10n-allow-file: test fixture titles, not shipped UI.
// The new-chat hero shows only for a chat that is new (ui-state-fixes M3): an existing chat whose
// summary has no turn count is still loading until its attach answers, not new; a chat with no
// session yet, one whose summary counts no turns, and one attached with no rows still are.
import { expect, test } from "bun:test";
import { isNewChat, shownChatName } from "./emptyStateModel";
import { slashMenuEmptyLabel } from "./composerModel";

type Snapshot = Parameters<typeof isNewChat>[0];
const existing = (extra: Record<string, unknown> = {}) =>
  ({
    sessionId: "chat-1",
    summary: { sessionId: "chat-1", title: "Fix the build" },
    sessions: [],
    rows: [],
    queue: [],
    isWorking: false,
    connection: "connected",
    ...extra,
  }) as unknown as Snapshot;

test("an existing chat whose summary has no turn count is not new while it attaches", () => {
  expect(isNewChat(existing())).toBe(false);
  expect(isNewChat(existing({ connection: "connecting" }))).toBe(false);
});

test("attached with no rows and no older history, it is new", () => {
  expect(isNewChat(existing({ chatRead: true }))).toBe(true);
  expect(isNewChat(existing({ chatRead: true, canLoadOlder: true }))).toBe(false);
});

test("a summary that counts its turns decides before the attach", () => {
  const counted = (turnCount: number) =>
    existing({ summary: { sessionId: "chat-1", title: "Fix the build", turnCount } });
  expect(isNewChat(counted(0))).toBe(true);
  expect(isNewChat(counted(3))).toBe(false);
});

test("a chat with no session yet is new", () => {
  const fresh = existing({ sessionId: undefined, summary: undefined });
  expect(isNewChat(fresh, true)).toBe(true);
});

const t = ((key: string) => ({ "sidebar.newChat": "New chat", "cmuxLink.kind.chat": "Chat" })[key] ?? key) as never;

test("an existing chat is not called New chat before its summary arrives", () => {
  expect(shownChatName(existing({ summary: undefined }), t)).toBe("Chat");
  expect(
    shownChatName(existing({ summary: undefined, sessions: [{ sessionId: "chat-1", title: "Fix the build" }] }), t),
  ).toBe("Fix the build");
  expect(shownChatName(existing({ sessionId: undefined, summary: undefined }), t)).toBe("New chat");
  expect(shownChatName(existing(), t)).toBe("Fix the build");
});

test("the / menu says it is loading until the chat's commands are read (M7)", () => {
  expect(slashMenuEmptyLabel([{}], true)).toBe("composer.loadingCommands");
  expect(slashMenuEmptyLabel(undefined, undefined)).toBe("composer.loadingCommands");
  expect(slashMenuEmptyLabel([], undefined)).toBe("composer.noCommands");
  expect(slashMenuEmptyLabel([{}], undefined)).toBe("composer.noMatchingCommands");
});

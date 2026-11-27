// Leo: "we also want to be able to properly motherf***ing run in a browser. we already have urls. we
// already have deeplinks. lets go." The browser sidebar groups chats by the person's cmux NEXT
// workspaces: a workspace's local chats leave the flat session list, and a search keeps a
// workspace when its name, title or one of its chats matches.
import { expect, test } from "bun:test";
import {
  linkedSessions,
  matchingWorkspaces,
  type BrowserWorkspaceChat,
  type BrowserWorkspaces,
} from "../src/agent-session/acpmux/browser/workspaces";

const chat = (tabId: string, title: string, extra: Partial<BrowserWorkspaceChat> = {}): BrowserWorkspaceChat => ({
  tabId,
  local: true,
  title,
  host: "This Mac",
  ...extra,
});

const workspaces: BrowserWorkspaces = {
  available: true,
  registryId: "install:this-mac",
  workspaces: [
    {
      id: "ws-a",
      name: "cmux",
      title: "Browser work",
      chats: [
        chat("tab-1", "Fix the sidebar", { sessionId: "chat-1" }),
        chat("tab-2", "Remote chat", { sessionId: "chat-2", local: false, host: "Other Mac" }),
        chat("tab-3", ""),
      ],
    },
    { id: "ws-b", name: "notes", title: null, chats: [chat("tab-4", "Release notes", { sessionId: "chat-4" })] },
    { id: "ws-c", name: "empty", chats: [] },
  ],
};

test("only a workspace's local chats with a session leave the flat list", () => {
  expect([...linkedSessions(workspaces)].sort()).toEqual(["chat-1", "chat-4"]);
  expect(linkedSessions(undefined).size).toBe(0);
  expect(linkedSessions({ available: false, workspaces: [] }).size).toBe(0);
});

test("a search keeps a workspace whose name, title or chat matches", () => {
  const ids = (needle: string, title = (row: BrowserWorkspaceChat) => row.title) =>
    matchingWorkspaces(workspaces, needle, title).map((workspace) => workspace.id);
  expect(ids("")).toEqual(["ws-a", "ws-b", "ws-c"]);
  expect(ids("browser")).toEqual(["ws-a"]);
  expect(ids("empty")).toEqual(["ws-c"]);
  expect(ids("release")).toEqual(["ws-b"]);
  expect(ids("remote")).toEqual(["ws-a"]);
  expect(ids("nothing")).toEqual([]);
  // The sidebar names a local chat by its listed session's title, not the tab's.
  expect(ids("renamed", (row) => (row.sessionId === "chat-4" ? "Renamed chat" : row.title))).toEqual(["ws-b"]);
  expect(matchingWorkspaces(undefined, "", (row) => row.title)).toEqual([]);
});

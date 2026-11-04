// A new chat's extra folders reach acpmux in its `session/new` (`additionalDirectories`, cmux#32811),
// on this Mac and on another machine, and belong to that one start: the next new chat starts with none.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, OrderedRows } from "../src/agent-session/acpmux/direct";

function recordingClient(): { client: AcpmuxDirectClient; sent: Record<string, unknown>[] } {
  const sent: Record<string, unknown>[] = [];
  const client = Object.create(AcpmuxDirectClient.prototype) as AcpmuxDirectClient;
  Object.assign(client as unknown as Record<string, unknown>, {
    host: {},
    selectionGeneration: 0,
    trustCancellation: 0,
    closed: false,
    replayMode: false,
    fedMode: false,
    disposed: false,
    rows: new OrderedRows(),
    sessions: [],
    askedSessions: [],
    asks: { sessions: () => undefined, list: () => [] },
    extensions: [],
    handoff: { state: {} },
    permissions: {
      state: { supported: false, ready: false, groups: [], chatAllowance: false, loading: false, busy: false },
    },
    queue: [],
    queueWithdrawn: [],
    waitingSteers: [],
    listener: () => undefined,
    subagents: {
      progressSource: { structureVersion: 0, takeChangedProgress: () => ({}) },
      views: () => [],
    },
    request: async (method: string, params: Record<string, unknown>) => {
      if (method === "session/new") sent.push(params);
      return { sessionId: `s${sent.length}` };
    },
  });
  return { client, sent };
}

test("a new chat in a project sees its extra folders beside it", async () => {
  const { client, sent } = recordingClient();
  client.setNewChatFolders({
    machine: "local",
    folders: ["/Users/you/notes", "/Users/you/src/cmux", "/Users/you/data"],
  });
  await client.startSession("claude", "/Users/you/src/cmux");
  expect(sent[0]!.cwd).toBe("/Users/you/src/cmux");
  // Never the chat's own folder.
  expect(sent[0]!.additionalDirectories).toEqual(["/Users/you/notes", "/Users/you/data"]);
  // The next new chat starts with none.
  await client.startSession("claude", "/Users/you/src/cmux");
  expect("additionalDirectories" in sent[1]!).toBe(false);
});

test("a chat with no project starts in its private folder, with the folders beside it", async () => {
  const { client, sent } = recordingClient();
  client.setNewChatFolders({ machine: "local", folders: ["/Users/you/notes"] });
  await client.startSession("codex", undefined, undefined, undefined, true);
  expect(sent[0]!.cwd).toBeUndefined();
  expect(sent[0]!.additionalDirectories).toEqual(["/Users/you/notes"]);
  expect((sent[0]!._meta as { acpmux: Record<string, unknown> }).acpmux.noProject).toBe(true);
});

test("a chat on another machine names that machine's folders", async () => {
  const { client, sent } = recordingClient();
  client.setNewChatFolders({ machine: "devbox", folders: ["/srv/data"] });
  await client.startSession("claude", "/srv/api", "devbox");
  expect(sent[0]!.additionalDirectories).toEqual(["/srv/data"]);
  expect((sent[0]!._meta as { acpmux: Record<string, unknown> }).acpmux.peer).toBe("devbox");
});

test("a failed start keeps the folders for the retry", async () => {
  const { client, sent } = recordingClient();
  let fail = true;
  (client as unknown as { request: unknown }).request = async (method: string, params: Record<string, unknown>) => {
    if (method !== "session/new") return undefined;
    sent.push(params);
    if (fail) throw new Error("down");
    return { sessionId: "s1" };
  };
  client.setNewChatFolders({ machine: "local", folders: ["/Users/you/notes"] });
  await expect(client.startSession("claude", "/Users/you/src/cmux")).rejects.toThrow("down");
  fail = false;
  await client.startSession("claude", "/Users/you/src/cmux");
  expect(sent[1]!.additionalDirectories).toEqual(["/Users/you/notes"]);
});

test("folders added for one machine never go to a chat on another", async () => {
  const { client, sent } = recordingClient();
  client.setNewChatFolders({ machine: "local", folders: ["/Users/you/notes"] });
  await client.startSession("claude", "/srv/api", "devbox");
  expect("additionalDirectories" in sent[0]!).toBe(false);
  // They wait for a chat on their own machine.
  await client.startSession("claude", "/Users/you/src/cmux");
  expect(sent[1]!.additionalDirectories).toEqual(["/Users/you/notes"]);
});

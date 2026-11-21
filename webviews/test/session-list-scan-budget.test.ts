// Leo, 2026-11-18: "Ok... we need to get fable 5.2 on the case for unfucking more boneheaded designs".
// The chat pane derives from the whole session list (10,790 chats at Leo's scale, ~4 changes a
// second). A keypress or a session change reads only the chats that changed, never every chat
// again: the `@` menu's titles (mentionItems.ts), a new chat's run location (runLocationDefault.ts),
// the sub-sessions' asks (subagents/childAsks.ts), the chat's Chief (managedBy.ts) and the names an
// addressed prompt's sender is looked up by (direct.ts `chatNames`). Each read is counted through a
// proxy on every entry, so the budget holds whatever the code caches.
// Bench with times: bun bench/session-list-scan.bench.ts.
import { expect, test } from "bun:test";
import { chatNames } from "../src/agent-session/acpmux/direct";
import { chiefOf } from "../src/agent-session/acpmux/managedBy";
import { mentionItems } from "../src/agent-session/acpmux/mentionItems";
import { folderRunLocation } from "../src/agent-session/acpmux/runLocationDefault";
import { noteReplaced } from "../src/agent-session/acpmux/sessionIndex";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import type { WatchedAsk } from "../src/agent-session/acpmux/needsYou/model";
import { childAsks } from "../src/agent-session/acpmux/subagents/childAsks";

const SIZE = 10_790;
const WORDS = ["fix", "sidebar", "refactor", "agent", "pane", "latency", "tests", "cloud", "review", "merge"];

/// The entries whose `fields` were read since the last `take`.
function reads(fields: readonly string[]) {
  const watched = new Set(fields);
  let seen = new Set<string>();
  return {
    wrap: <T extends { sessionId: string }>(entry: T): T =>
      new Proxy(entry, {
        get(target, key, receiver) {
          if (typeof key === "string" && watched.has(key)) seen.add(target.sessionId);
          return Reflect.get(target, key, receiver);
        },
      }),
    take() {
      const count = seen.size;
      seen = new Set();
      return count;
    },
  };
}

function entry(index: number, version = 0): AcpmuxSessionEntry {
  const words = Array.from({ length: 12 }, (_, at) => WORDS[(index * 7 + at * 3) % WORDS.length]).join(" ");
  return {
    sessionId: `s${index}`,
    name: `agent-${index}`,
    lastPrompt: `${words} ${index}`,
    ...(index % 5 === 0 ? { displayTitle: `Task ${index}: ${words}` } : {}),
    cwd: `/Users/leo/Projects/repo-${index % 300}/./src/../`,
    ...(index % 9 === 0 ? { peer: `mac-${index % 7}`, shortName: `short-${index}` } : {}),
    ...(index % 4 === 1 ? { startedBy: `s${index - 1}` } : {}),
    ...(index % 50 === 0 ? { chiefChild: true, chiefHome: "home-1" } : {}),
    ...(index === 2002 ? { chiefTurn: { home: "home-1", participant: "chief-1" } } : {}),
    createdAt: index,
    updatedAt: index + version,
  } as AcpmuxSessionEntry;
}

/// `from` with the entry at `at` changed, as direct.ts `sessionChanged` makes the next list.
function changed<T extends { sessionId: string }>(from: readonly T[], at: number, next: T): T[] {
  const to = from.slice();
  to[at] = next;
  noteReplaced(from, to, [at]);
  return to;
}

const titles = (items: ReturnType<typeof mentionItems>) =>
  items.flatMap((item) => (item.kind === "session" ? [`${item.sessionId} ${JSON.stringify(item.name)}`] : []));

test("a keypress with an open @ menu reads the changed chats' titles, not every chat's", () => {
  const counted = reads(["displayTitle", "lastPrompt", "title", "name"]);
  let sessions = Array.from({ length: SIZE }, (_, index) => counted.wrap(entry(index)));
  mentionItems({ query: "", files: [], sessions, chatId: "s0" });
  counted.take();
  const word = "refact";
  for (let key = 1; key <= word.length; key++) {
    mentionItems({ query: word.slice(0, key), files: [], sessions, chatId: "s0" });
    expect({ key, read: counted.take() }).toEqual({ key, read: 0 });
  }
  // Another machine's chat changes mid-word: only it is read again.
  sessions = changed(sessions, 4321, counted.wrap(entry(4321, 1)));
  mentionItems({ query: word, files: [], sessions, chatId: "s0" });
  expect(counted.take()).toBeLessThanOrEqual(1);
});

test("the @ menu lists what a fresh list gives it, as the word grows, shrinks and the list changes", () => {
  let sessions = Array.from({ length: 2000 }, (_, index) => entry(index));
  const fresh = (query: string) => titles(mentionItems({ query, files: [], sessions: [...sessions], chatId: "s3" }));
  for (const query of ["", "r", "re", "ref", "refactor", "refactorz", "re", "task 1", "task 12", "s"]) {
    expect(titles(mentionItems({ query, files: [], sessions, chatId: "s3" }))).toEqual(fresh(query));
    sessions = changed(sessions, 7, { ...entry(7), displayTitle: `Refactor ${query}` });
  }
});

test("a session change reads O(changed) entries for the run location, the sub-sessions' asks and the Chief", () => {
  const counted = reads(["cwd", "sessionId", "chiefTurn"]);
  let sessions = Array.from({ length: SIZE }, (_, index) => counted.wrap(entry(index)));
  const asks = [1, 5, 9].map((index) => ({
    sessionId: `s${index}`,
    at: index,
    permission: { permissionId: `p${index}`, pending: true, options: [] },
  })) as unknown as WatchedAsk[];
  const derive = () => ({
    folder: (folderRunLocation("/Users/leo/Projects/repo-7/src", sessions, {}), counted.take()),
    asks: (childAsks(asks, sessions, "s0"), counted.take()),
    chief: (chiefOf("s50", sessions), counted.take()),
  });
  derive();
  for (let change = 0; change < 20; change++) {
    const at = (change * 211) % SIZE;
    sessions = changed(sessions, at, counted.wrap(entry(at, change + 1)));
    const read = derive();
    expect(read.folder).toBeLessThanOrEqual(1);
    expect(read.asks).toBeLessThanOrEqual(asks.length + 1);
    expect(read.chief).toBeLessThanOrEqual(2);
  }
  expect(chiefOf("s50", sessions)).toBe("chief-1");
});

test("an addressed prompt's sender is looked up in a name index made once per list", () => {
  const counted = reads(["name", "shortName"]);
  const sessions = Array.from({ length: SIZE }, (_, index) => counted.wrap(entry(index)));
  const index = chatNames(sessions as never);
  expect(counted.take()).toBe(SIZE);
  // A refold of 100 addressed prompts reads no entry again.
  for (let prompt = 0; prompt < 100; prompt++) chatNames(sessions as never).names.has(`sender-${prompt}`);
  expect(counted.take()).toBe(0);
  // What namesChat answers: a chat's name, its short name, a peer's chat by its bare name.
  expect(index.names.has("agent-12")).toBe(true);
  expect(index.names.has("short-18")).toBe(true);
  expect(chatNames([{ sessionId: "p", name: " mac/lane ", peer: "mac" }] as never).names.has("lane")).toBe(true);
  expect(chatNames([{ sessionId: "p", name: "lane", peer: "mac" }] as never).names.has("mac/lane")).toBe(false);
  expect(index.byId.get("s42")?.sessionId).toBe("s42");
});

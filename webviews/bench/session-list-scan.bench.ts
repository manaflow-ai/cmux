// What the chat pane reads of the whole session list per keypress and per session change, at Leo's
// scale (10,790 chats, ~2,500 started by another chat). Each arm runs on the same lists:
//   mention:  ms per key of a 6-key `@` word (Composer.tsx `mentions`, mentionItems.ts), and the
//             chats whose title it read per key;
//   change:   one chat changes (direct.ts `sessionChanged`: a new list, one entry replaced), then the
//             pane's derivations run again: the new chat's run location (App.tsx `folderDefault`,
//             runLocationDefault.ts), the sub-sessions' asks (subagents/childAsks.ts) and the chat's
//             Chief (managedBy.ts `chiefOf`); ms per change, and the entries each read per change.
//   bun bench/session-list-scan.bench.ts [rounds=9] [sessions=10790]
import { mentionItems } from "../src/agent-session/acpmux/mentionItems";
import { folderRunLocation } from "../src/agent-session/acpmux/runLocationDefault";
import { childAsks } from "../src/agent-session/acpmux/subagents/childAsks";
import { chiefOf } from "../src/agent-session/acpmux/managedBy";
import { noteReplaced } from "../src/agent-session/acpmux/sessionIndex";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import type { WatchedAsk } from "../src/agent-session/acpmux/needsYou/model";

const ROUNDS = Number(process.argv[2] ?? 9);
const SIZE = Number(process.argv[3] ?? 10_790);
const QUERY = "refact";
const CHANGES = 50;

/// The entries whose `field` was read since the last `take`, through a proxy on each entry.
class Reads {
  private seen = new Set<string>();
  constructor(private readonly fields: ReadonlySet<string>) {}
  wrap(entry: AcpmuxSessionEntry): AcpmuxSessionEntry {
    return new Proxy(entry, {
      get: (target, key, receiver) => {
        if (typeof key === "string" && this.fields.has(key)) this.seen.add(target.sessionId);
        return Reflect.get(target, key, receiver);
      },
    });
  }
  take(): number {
    const count = this.seen.size;
    this.seen = new Set();
    return count;
  }
}

const WORDS = ["fix", "sidebar", "refactor", "agent", "pane", "latency", "tests", "cloud", "review", "merge"];
function entry(index: number, version = 0): AcpmuxSessionEntry {
  const words = Array.from({ length: 12 }, (_, at) => WORDS[(index * 7 + at * 3) % WORDS.length]).join(" ");
  const started = index % 4 === 1;
  return {
    sessionId: `s${index}`,
    name: `agent-${index}`,
    lastPrompt: `${words} in the ${index % 97} folder, then run the suite and report back`,
    ...(index % 5 === 0 ? { displayTitle: `Task ${index}: ${words}` } : {}),
    cwd: `/Users/leo/Projects/repo-${index % 300}/./src/../`,
    ...(index % 9 === 0 ? { peer: `mac-${index % 7}` } : {}),
    ...(started ? { startedBy: `s${index - 1}` } : {}),
    ...(index % 50 === 0 ? { chiefChild: true, chiefHome: `home-${index % 3}` } : {}),
    ...(index % 1000 === 2 ? { chiefTurn: { home: `home-${index % 3}`, participant: "agent_mux" } } : {}),
    createdAt: index,
    updatedAt: index + version,
  } as AcpmuxSessionEntry;
}

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
const fmt = (ms: number) => ms.toFixed(3);
/// Each arm runs twice: on plain entries for the times (a proxy's trap costs more than the work), and
/// on proxied ones for the reads.
const ARMS = [false, true] as const;

// mention: one list, a 6-key word typed over it.
{
  const titles = new Reads(new Set(["displayTitle", "lastPrompt", "title"]));
  const perKey: number[] = [];
  let read = 0;
  for (const counting of ARMS)
    for (let round = 0; round < ROUNDS; round++) {
      const sessions = Array.from({ length: SIZE }, (_, index) =>
        counting ? titles.wrap(entry(index, round)) : entry(index, round),
      );
      // The bare `@` before the word's first key: the menu opens on it.
      mentionItems({ query: "", files: [], sessions, chatId: "s0" });
      titles.take();
      for (let key = 1; key <= QUERY.length; key++) {
        const start = performance.now();
        mentionItems({ query: QUERY.slice(0, key), files: [], sessions, chatId: "s0" });
        if (!counting) perKey.push(performance.now() - start);
        read = Math.max(read, titles.take());
      }
    }
  console.log(`mention  sessions=${SIZE} ms/key p50=${fmt(median(perKey))} titles read/key max=${read}`);
}

// change: one chat changes at a time; the pane's derivations run again on each new list.
{
  const fields = new Reads(new Set(["cwd", "sessionId", "chiefTurn"]));
  const asks: WatchedAsk[] = Array.from({ length: 4 }, (_, at) => ({
    sessionId: `s${at * 4 + 1}`,
    at,
    permission: { permissionId: `p${at}`, pending: true, options: [] },
  })) as unknown as WatchedAsk[];
  const ms = { folder: [] as number[], asks: [] as number[], chief: [] as number[] };
  const read = { folder: 0, asks: 0, chief: 0 };
  for (const counting of ARMS)
    for (let round = 0; round < ROUNDS; round++) {
      const make = (index: number, version: number) =>
        counting ? fields.wrap(entry(index, version)) : entry(index, version);
      let sessions = Array.from({ length: SIZE }, (_, index) => make(index, round));
      const derive = (record: boolean) => {
        for (const [name, run] of [
          ["folder", () => folderRunLocation("/Users/leo/Projects/repo-7/src", sessions, {})],
          ["asks", () => childAsks(asks, sessions, "s0")],
          ["chief", () => chiefOf("s50", sessions)],
        ] as const) {
          const start = performance.now();
          run();
          const took = performance.now() - start;
          const count = fields.take();
          if (!record) continue;
          if (!counting) ms[name].push(took);
          read[name] = Math.max(read[name], count);
        }
      };
      derive(false);
      for (let change = 0; change < CHANGES; change++) {
        const at = (change * 211) % SIZE;
        const from = sessions;
        sessions = from.slice();
        sessions[at] = make(at, round + change + 1);
        noteReplaced(from, sessions, [at]);
        derive(true);
      }
    }
  for (const name of ["folder", "asks", "chief"] as const)
    console.log(
      `change   ${name.padEnd(6)} sessions=${SIZE} ms/change p50=${fmt(median(ms[name]))} entries read/change max=${read[name]}`,
    );
}

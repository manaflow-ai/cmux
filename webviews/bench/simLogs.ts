// l10n-allow-file: bench fixture reader, not shipped UI.
// A chat-sim transcript as the load benches' stand-in acpmux serves it (Leo, 2026-11-22: "testing under duress. you
// should also be able to simulate duress 'offline' aka without a true agent thing, just like how i introduced that
// stuff in the gui"). The chat simulator (src/agent-session/acpmux/sim/README.md) folds a scenario's records through
// the pane's reducer but never loads a page; this reads the same records for a bench that does:
//   a scenario's name   (`bun scripts/chat-sim.ts --list`): its records, built on its virtual clock;
//   long:N              N turns of mixed work (chat-sim `--long N`, about 25 records a turn);
//   a path              an .ndjson of records (chat-sim `--emit-ndjson`, `--sanitize`, a fixture) or a session
//                       directory (~/.acpmux/sessions/<id>, its events/*.ndjson), as chat-sim `--replay` reads it.
// `simChat` then cuts the records into what the daemon holds when the app restarts and, for a running chat, the
// records the agent writes after it (first-load-after-restart.bench.ts SIM=, RUNNING=1).
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { parseRecords } from "../src/agent-session/acpmux/sim/sanitize";
import { SCENARIOS, longRun, scenarioNames } from "../src/agent-session/acpmux/sim/scenarios";

export type SimLog = {
  /// The scenario's name, `long-N`, or the file's.
  name: string;
  /// The harness family the scenario folds by (chat-sim scenarios: claude); unknown for a file.
  family?: string;
  /// Oldest first, every one in `sessionId`.
  records: EventRecord[];
};

/// The records of `spec` (a chat-sim scenario name, `long:N`, or an .ndjson file or session directory), each
/// moved into the chat `sessionId`, sorted by seq.
export function simLog(spec: string, sessionId: string): SimLog {
  const own = (records: readonly EventRecord[]) =>
    [...records].sort((a, b) => a.seq - b.seq).map((record) => ({ ...record, sessionId }));
  const long = /^long:(\d+)$/.exec(spec);
  if (long) {
    const turns = Number(long[1]);
    if (!Number.isSafeInteger(turns) || turns < 1) throw new Error(`SIM=long:N needs N of at least 1, not ${spec}`);
    const scenario = longRun(turns);
    return { name: scenario.name, family: scenario.family, records: own(scenario.events) };
  }
  const make = Object.hasOwn(SCENARIOS, spec) ? SCENARIOS[spec] : undefined;
  if (make) {
    const scenario = make();
    return { name: scenario.name, family: scenario.family, records: own(scenario.events) };
  }
  const file = spec.replace(/^~(?=$|\/)/, process.env.HOME ?? "~");
  if (!existsSync(file))
    throw new Error(`SIM=${spec} is no chat-sim scenario (${scenarioNames().join(", ")}), long:N, or file`);
  const records = own(readRecords(file));
  if (records.length === 0) throw new Error(`SIM=${spec} holds no records`);
  return { name: path.basename(file), records };
}

/// A session directory's records (events/*.ndjson), or one NDJSON file's, as chat-sim `--replay` reads them.
export function readRecords(file: string): EventRecord[] {
  if (!statSync(file).isDirectory()) return parseRecords(readFileSync(file, "utf8"));
  const dir = existsSync(path.join(file, "events")) ? path.join(file, "events") : file;
  return readdirSync(dir)
    .filter((name) => name.endsWith(".ndjson"))
    .sort()
    .flatMap((name) => parseRecords(readFileSync(path.join(dir, name), "utf8")));
}

const isPrompt = (record: EventRecord) => record.dir === "mux" && record.kind === "user_message";
const replyText = (record: EventRecord): string | undefined => {
  if (record.kind !== "agent_message_chunk") return undefined;
  const content = record.msg?.params?.update?.content;
  return typeof content?.text === "string" ? content.text : undefined;
};

/// Text a reader sees in the newest reply of `records`: the longest plain run (letters, digits, spaces and
/// sentence marks, no Markdown) of its last streamed message, at most 60 characters. A bench waits until a row in
/// view holds it, as it waits for `Answer N:` in its own chats. Undefined when the records hold no reply.
export function newestReplyMarker(records: readonly EventRecord[]): string | undefined {
  let end = records.length - 1;
  while (end >= 0 && replyText(records[end]!) === undefined) end -= 1;
  if (end < 0) return undefined;
  // The message is the run of chunks up to the next record of another kind (a call, a turn's end).
  let start = end;
  while (start > 0 && replyText(records[start - 1]!) !== undefined) start -= 1;
  const text = records
    .slice(start, end + 1)
    .map((record) => replyText(record) ?? "")
    .join("");
  const runs = text.match(/[\p{L}\p{N}][\p{L}\p{N} ,.:;'?!-]*/gu) ?? [];
  const best = runs
    .flatMap((run) => run.split(/\s{2,}/))
    .map((run) => run.trim().slice(0, 60).trim())
    .sort((a, b) => b.length - a.length)[0];
  return best && best.length >= 4 ? best : undefined;
}

export type SimChat = {
  /// What the daemon holds when the app restarts: every record, or (running) up to a turn just started.
  served: EventRecord[];
  /// Running only: the records the agent writes after the restart, oldest first.
  rest: EventRecord[];
  /// The newest reply's text in `served` (newestReplyMarker).
  latest: string;
  /// Turns started in `served` (prompts and other agents' messages).
  turns: number;
  /// The turn still running at the end of `served`, for the chat's summary, else undefined.
  turn?: { turnId: string; promptId: string; startedAt: number; prompt: string };
};

/// Cuts `log` for a restart. Finished (`running` false): every record is served. Running: about the newest
/// `restRecords` (at most half the chat) are held back to stream after the restart, and the cut moves on to just
/// after the next turn's start, so the served chat ends inside a turn that has only begun, as a working agent's
/// does when the app restarts.
export function simChat(log: SimLog, { running, restRecords }: { running: boolean; restRecords: number }): SimChat {
  const { records } = log;
  let cut = records.length;
  if (running) {
    const held = Math.max(1, Math.min(Math.ceil(restRecords), Math.floor(records.length / 2)));
    const from = records.length - held;
    const started = (at: number) => records[at]!.kind === "turn_started";
    let at = from;
    while (at < records.length && !started(at)) at += 1;
    if (at >= records.length) for (at = from - 1; at >= 0 && !started(at); at -= 1);
    if (at < 0) throw new Error(`SIM=${log.name} starts no turn, so it cannot run through a restart (RUNNING=1)`);
    cut = at + 1;
    if (cut >= records.length) throw new Error(`SIM=${log.name} writes nothing after its last turn starts`);
  }
  const served = records.slice(0, cut);
  const latest = newestReplyMarker(served);
  if (!latest) throw new Error(`SIM=${log.name} has no reply before the restart to wait for`);
  const opener = [...served].reverse().find(isPrompt);
  return {
    served,
    rest: records.slice(cut),
    latest,
    turns: served.filter(isPrompt).length,
    ...(running && opener
      ? {
          turn: {
            turnId: String(opener.msg?.turnId ?? `turn-${opener.seq}`),
            promptId: String(opener.msg?.promptId ?? `prompt-${opener.seq}`),
            startedAt: served.at(-1)!.at,
            prompt: String(opener.msg?.text ?? ""),
          },
        }
      : {}),
  };
}

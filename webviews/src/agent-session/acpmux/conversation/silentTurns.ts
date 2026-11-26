// Turns something other than the person started that said nothing to them leave the transcript and
// go into the composer hat as one finished line each (subagents/SubagentTray.tsx, kind `turn`). Leo,
// 2026-11-25, on a transcript of bare "Worked for 3s >" rows with nothing between them: "so... why
// were these 0 text output from you (is that a personal setting on my end)", then "oh. i guess if
// there was no reply... but you still had the worked for/thinking... should it stay in the
// transcript or just get folded into the composer hat?". The hat it is.
//
// A turn is silent when all of these hold:
// - Something other than the person started it: acpmux's background turn (a task's or a subagent's
//   end, a scheduled wakeup, a hook; backgroundTurns.ts), or a prompt that is not the person's
//   (acpmux's inbox notice, a task notification, bookkeeping, a tool's notice; incomingMessage.ts)
//   that started work. Another agent's message is words for the person and stays, as does a fire.
// - It ended: a running turn stays where it runs until it ends.
// - It said nothing that draws: no reply with words, or acpmux called it quiet (its reply is hidden
//   then anyway). A failed task's turn always stays.
// - Its rows are only work: calls, thoughts, a compaction and its footer. Anything else (an ask, a
//   permission, a plan, a failure, a card) keeps the whole turn where it is.
// - It had no effects: no file edit, no message to another agent or chat, no PR opened, merged or
//   landed, no push. Such a turn keeps its one folded "Worked for" line in the transcript, since work
//   happened there.
import type { AcpmuxActivity, AcpmuxBackgroundTurn, AcpmuxRow } from "../model";
import { continuesTurn, opensTurn } from "../turnStart";
import { BACKGROUND_TURN, backgroundWeight } from "./backgroundTurns";
import { toolGroups } from "./toolGroups";
import { isVisiblyEmptyMessage } from "./visibleMessage";

/// One silent turn, as the hat lists it.
export type SilentTurn = {
  /// Its opener's row id: the hat line's key.
  id: string;
  /// The background turn acpmux recorded, which names what started it; none for a prompt's turn.
  background?: AcpmuxBackgroundTurn;
  startedAt: number;
  endedAt: number;
  /// What a quiet turn wrote that the transcript never drew.
  reply?: string;
  /// Each call's words, in order (at most `MAX_STEPS`).
  steps: readonly string[];
};

export type SilentSplit = { rows: AcpmuxRow[]; silent: readonly SilentTurn[] };

const MAX_STEPS = 12;
const NONE: readonly SilentTurn[] = [];

/// Shell commands with an effect past the turn: a PR opened, changed, merged or landed, a push, a
/// message to a person or another agent.
const EFFECT_COMMAND =
  /\b(?:gh\s+pr\s+(?:create|merge|close|edit|comment|review|ready)|glaeda-gh\s+(?:land|merge)|git\s+push|wt\s+push|slack-post|acpmux\s+(?:send|task\s+done|deliver|inbox\s+send)|cmux\s+agent\s+message)\b/;
const EDIT_KINDS = new Set(["edit", "fileChange", "delete", "move"]);

/// Whether `items` did something past the turn (see the file's head).
function hasEffects(items: readonly AcpmuxActivity[]): boolean {
  for (const item of items) {
    const tool = item.tool;
    if (!tool) continue;
    if (tool.kind && EDIT_KINDS.has(tool.kind)) return true;
    if (EFFECT_COMMAND.test(tool.command ?? "") || EFFECT_COMMAND.test(tool.title)) return true;
  }
  return toolGroups(items).some(
    (group) =>
      group.type === "send" ||
      group.type === "sendGroup" ||
      group.type === "message" ||
      group.type === "subsession" ||
      group.type === "subsessionGroup",
  );
}

/// A prompt that is not the person's and is no fire: its turn may be silent.
function agentOpener(row: AcpmuxRow): boolean {
  const incoming = row.incoming;
  if (row.kind !== "user" || !incoming || row.pending || row.failed || row.received) return false;
  if (incoming.kind === "inbox" || incoming.kind === "notice" || incoming.kind === "hidden") return true;
  // Another agent's message is words for the person; only a tool's notice that is no fire may go.
  return (
    incoming.kind === "message" &&
    !incoming.message.fromPerson &&
    incoming.message.notice !== undefined &&
    incoming.message.notice.severity !== "fire"
  );
}

/// Reads one turn's own rows; undefined as soon as one keeps the turn in the transcript.
function readWork(rows: readonly AcpmuxRow[], quiet: boolean): Work | undefined {
  const items: AcpmuxActivity[] = [];
  let reply = "";
  let endedAt = 0;
  for (const row of rows) {
    endedAt = Math.max(endedAt, row.workEndedAt ?? row.at);
    switch (row.kind) {
      case "activity":
        items.push(...(row.items ?? []));
        break;
      case "assistant":
        if (isVisiblyEmptyMessage(row)) break;
        if (!quiet) return undefined;
        reply += (reply ? "\n" : "") + (row.text ?? "").trim();
        break;
      case "turnSummary":
        if (row.status !== undefined && row.status !== "completed") return undefined;
        if (row.durationMs !== undefined) endedAt = Math.max(endedAt, rows[0]!.at + row.durationMs);
        break;
      case "compaction":
        break;
      default:
        return undefined;
    }
  }
  if (items.some((item) => item.status === "failed" || item.tool?.status === "failed")) return undefined;
  if (hasEffects(items)) return undefined;
  return { items, reply, endedAt };
}

type Work = { items: AcpmuxActivity[]; reply: string; endedAt: number };

/// Each turn's reading by its opener row, kept while its rows are the same objects: a streamed
/// snapshot rebuilds only the rows that changed (direct.ts), so a long chat's ended turns are read
/// once, never per token.
const readings = new WeakMap<AcpmuxRow, { own: readonly AcpmuxRow[]; quiet: boolean; work: Work | undefined }>();

function readTurn(opener: AcpmuxRow, own: readonly AcpmuxRow[], quiet: boolean): Work | undefined {
  const kept = readings.get(opener);
  if (kept && kept.quiet === quiet && kept.own.length === own.length && kept.own.every((row, at) => row === own[at]))
    return kept.work;
  const work = readWork(own, quiet);
  readings.set(opener, { own, quiet, work });
  return work;
}

const stepsOf = (items: readonly AcpmuxActivity[]): string[] =>
  items
    .flatMap((item) => (item.tool ? [item.tool.description || item.tool.title] : []))
    .filter((step) => step.trim() !== "")
    .slice(0, MAX_STEPS);

function silentTurn(id: string, startedAt: number, work: Work, background?: AcpmuxBackgroundTurn): SilentTurn {
  return {
    id,
    ...(background && { background }),
    startedAt,
    endedAt: Math.max(startedAt, work.endedAt),
    ...(work.reply && { reply: work.reply }),
    steps: stepsOf(work.items),
  };
}

/// A row that changes no turn's reading while the chat's last turn runs: no prompt (every turn
/// boundary is a `user` row, turnStart.ts), no background turn line and none of one's rows.
const inertTail = (row: AcpmuxRow): boolean =>
  row.kind !== "user" && row.kind !== BACKGROUND_TURN && row.inBackground === undefined;

/// The last split, which the next reuses when only the running turn's tail changed.
let lastSplit: { rows: readonly AcpmuxRow[]; split: SilentSplit } | undefined;

/// `rows` without the silent turns' rows, and those turns oldest first. `working`: the chat's last
/// turn still runs, so it stays. Without a silent turn, `rows` itself.
///
/// A streamed token, thought or call replaces or appends rows of the running last turn and keeps
/// every other row object (direct.ts): such a split is the last one with its tail swapped, a
/// pointer compare per row instead of reading every turn again. The running turn always stays
/// (`working`), and a tail of inert rows (`inertTail`) moves no turn's bounds, so the split's
/// drop set and silent turns are the same.
export function splitSilentTurns(rows: AcpmuxRow[], working: boolean): SilentSplit {
  const last = lastSplit;
  if (working && last && rows.length >= last.rows.length && last.rows !== rows) {
    const prev = last.rows;
    let same = 0;
    while (same < prev.length && prev[same] === rows[same]) same += 1;
    // Rows past `same` hold no prompt, so they sit in the chat's last turn, which runs and stays:
    // the last split kept them as its own last rows (checked, never assumed).
    const tailReusable =
      same > 0 &&
      prev.slice(same).every(inertTail) &&
      rows.slice(same).every(inertTail) &&
      (last.split.rows === prev || tailKept(prev, same, last.split.rows));
    if (tailReusable) {
      const split: SilentSplit =
        last.split.rows === prev
          ? { rows, silent: last.split.silent }
          : {
              rows: [...last.split.rows.slice(0, last.split.rows.length - (prev.length - same)), ...rows.slice(same)],
              silent: last.split.silent,
            };
      lastSplit = { rows, split };
      return split;
    }
  }
  const split = splitSilentTurnsFull(rows, working);
  lastSplit = working ? { rows, split } : undefined;
  return split;
}

/// Whether the last split kept `prev`'s rows from `from` on, as its own last rows.
function tailKept(prev: readonly AcpmuxRow[], from: number, kept: readonly AcpmuxRow[]): boolean {
  const offset = kept.length - (prev.length - from);
  if (offset < 0) return false;
  for (let at = from; at < prev.length; at += 1) if (kept[offset + at - from] !== prev[at]) return false;
  return true;
}

/// The split read from every row, no reuse (tests compare the reused split with it).
export function splitSilentTurnsFull(rows: AcpmuxRow[], working: boolean): SilentSplit {
  // Cheap first: a chat with no turn another agent or a task started has nothing to split.
  if (!rows.some((row) => row.kind === BACKGROUND_TURN || agentOpener(row))) return { rows, silent: NONE };
  const drop = new Set<string>();
  const silent: SilentTurn[] = [];
  // Background turns: their line and the rows they made (`inBackground`), wherever they sit.
  const members = new Map<string, AcpmuxRow[]>();
  for (const row of rows)
    if (row.inBackground !== undefined) {
      const list = members.get(row.inBackground);
      if (list) list.push(row);
      else members.set(row.inBackground, [row]);
    }
  for (const row of rows) {
    const turn = row.background;
    if (row.kind !== BACKGROUND_TURN || !turn || turn.running || turn.ownTurn) continue;
    if (backgroundWeight(turn) === "failure") continue;
    const own = members.get(turn.id) ?? [];
    const work = readTurn(row, own, turn.quiet === true);
    if (!work) continue;
    drop.add(row.id);
    for (const member of own) drop.add(member.id);
    silent.push(silentTurn(row.id, row.at, work, turn));
  }
  // Prompts' turns: the opener up to the next prompt that opens one, without the background turns'
  // rows among them.
  let at = 0;
  while (at < rows.length) {
    if (!(opensTurn(rows[at]!) && !rows[at]!.pending && !rows[at]!.failed)) {
      at += 1;
      continue;
    }
    const start = at++;
    while (at < rows.length) {
      const row = rows[at]!;
      if (row.kind === "user" && !row.pending && !row.failed && !continuesTurn(row)) break;
      at += 1;
    }
    const opener = rows[start]!;
    if (!agentOpener(opener) || (working && at === rows.length)) continue;
    const own = rows
      .slice(start + 1, at)
      .filter((row) => row.kind !== BACKGROUND_TURN && row.inBackground === undefined);
    if (own.some((row) => row.kind === "user")) continue;
    const work = readTurn(opener, own, false);
    // A prompt with no work after it is only its own line; it stays.
    if (!work || work.items.length === 0) continue;
    drop.add(opener.id);
    for (const row of own) drop.add(row.id);
    silent.push(silentTurn(opener.id, opener.at, work));
  }
  if (silent.length === 0) return { rows, silent: NONE };
  silent.sort((a, b) => a.startedAt - b.startedAt || a.id.localeCompare(b.id));
  return { rows: rows.filter((row) => !drop.has(row.id)), silent };
}

import { utf8Length } from "../memory/text.ts";
import type { MemoResult, MemoryView } from "../memory-service.ts";

/**
 * The chief's turn (plans/cmux-next/chief.md section 5): no transcript. Each
 * turn appends the new events to memory, pays the compressions the cover
 * needs, then asks the model with only the cover and the new events. The
 * reply and any spawns are appended to memory as the chief's own entries.
 *
 * The model and the memory are ports, so the same function runs on PiHarness
 * in the ChiefDO and on a fake model in tests.
 */

export interface ChiefEvent {
  /** Stable id of the event (a message id, a worker turn id); keys make retries safe. */
  readonly id: string;
  readonly kind: "human" | "worker";
  /** Display name: the person, or the worker's name. */
  readonly from: string;
  readonly text: string;
}

export interface SpawnCall {
  readonly name: string;
  readonly prompt: string;
}

export interface ModelRequest {
  readonly system: string;
  readonly user: string;
  /** Whether the spawn tool is offered (not for compressions). */
  readonly tools: boolean;
}

export interface ModelReply {
  readonly text: string;
  readonly spawns: ReadonlyArray<SpawnCall>;
}

export interface ModelPort {
  complete(request: ModelRequest): Promise<ModelReply>;
}

export interface MemoryPort {
  view(): Promise<MemoryView>;
  note(texts: Array<string>, key: string): Promise<{ first: number; count: number } | { error: string }>;
  nap(block: string, text: string, key: string): Promise<MemoResult>;
}

/** Longest memory entry, in bytes (OptMem's default ENTRY_CHARS). */
export const ENTRY_BYTES = 280;
/** Compressions paid after a turn, when the cover does not need them yet. */
export const SPARE_NAPS = 4;
/** Compressions one turn may pay before it gives up (a memory imported without its tree). */
export const MAX_NAPS = 256;

export const CHIEF_SYSTEM = `You are Chief: one long-lived manager agent for one person, and the only one they talk to.

You have no chat history. Everything you know is in <memory>: your memory log, rebuilt for every
turn. "#n date text" is one entry, word for word. "#a-b text" is your own one-line summary of
entries a to b. Older entries are summarized more coarsely; the newest are exact. Entries are
written for you: the person's messages, your replies, what you spawned, and what workers reported.

You do no work yourself. Your only tool is spawn: it starts a worker agent with the real tools, or
sends a new prompt to a worker you started before (use the same name). Give a worker everything it
needs in the prompt: it does not share your memory. Workers report back as new events.

Reply to the person in one or two short sentences. Your reply is stored in your memory, and only
its first ${ENTRY_BYTES} bytes are kept, so put what matters first.`;

export const NAP_SYSTEM = `You compress your own memory. Answer with the one line the prompt asks for and nothing
else: no preamble, no quotes, no line breaks.`;

/** Cuts text to at most `max` UTF-8 bytes on a character boundary, at a word boundary when one is near. */
export function cutBytes(text: string, max: number): string {
  if (utf8Length(text) <= max) return text;
  let out = "";
  for (const ch of text) {
    if (utf8Length(out + ch) > max) break;
    out += ch;
  }
  const space = out.lastIndexOf(" ");
  return space > out.length / 2 ? out.slice(0, space) : out;
}

const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

/** One memory entry for an event: `who: text`, cut to fit, with a reference when cut. */
export function entryFor(who: string, text: string, ref?: string): string {
  const full = oneLine(`${who}: ${text}`);
  if (utf8Length(full) <= ENTRY_BYTES) return full;
  const tail = ref ? ` [${ref}]` : " …";
  return `${cutBytes(full, ENTRY_BYTES - utf8Length(tail))}${tail}`;
}

/** What the model reads: the cover and the new events, in full. Nothing else. */
export function turnInput(lines: ReadonlyArray<string>, events: ReadonlyArray<ChiefEvent>): string {
  const memory = lines.length > 0 ? lines.join("\n") : "(empty: this is your first turn)";
  const news = events.map((e) =>
    e.kind === "human" ? `${e.from} says:\n${e.text}` : `Worker ${e.from} reports:\n${e.text}`,
  );
  return `<memory>\n${memory}\n</memory>\n\nNew since your last turn (already appended to your memory):\n\n${news.join("\n\n")}`;
}

/** Pays one compression with the model. Returns false when nothing was pending. */
async function napOnce(memory: MemoryPort, model: ModelPort, view: MemoryView): Promise<boolean> {
  if (!view.nap) return false;
  const reply = await model.complete({ system: NAP_SYSTEM, user: view.nap.prompt, tools: false });
  const line = cutBytes(oneLine(reply.text), ENTRY_BYTES) || "(no summary)";
  const result = await memory.nap(view.nap.block, line, `nap:${view.nap.block}`);
  if (result.code !== 0) throw new Error(`nap ${view.nap.block} refused: ${result.stderr.trim()}`);
  return true;
}

export interface TurnResult {
  readonly reply: string;
  readonly spawns: ReadonlyArray<SpawnCall>;
  /** Compressions paid in this turn (before and after the model call). */
  readonly naps: number;
}

/**
 * Runs one turn for `events` (in arrival order). `turnId` keys the writes, so
 * running the same turn again after a crash appends nothing twice.
 */
export async function runTurn(
  turnId: string,
  events: ReadonlyArray<ChiefEvent>,
  memory: MemoryPort,
  model: ModelPort,
): Promise<TurnResult> {
  if (events.length === 0) throw new Error("a turn needs at least one event");
  const ingested = await memory.note(
    events.map((e) => entryFor(e.kind === "human" ? e.from : `worker ${e.from}`, e.text, e.id)),
    `turn:${turnId}:in`,
  );
  if ("error" in ingested) throw new Error(`events refused by memory: ${ingested.error}`);

  let naps = 0;
  let view = await memory.view();
  while (view.lines === undefined) {
    if (naps >= MAX_NAPS || !(await napOnce(memory, model, view))) {
      throw new Error(`memory cover needs ${view.missing ?? "a summary"} and it could not be built`);
    }
    naps++;
    view = await memory.view();
  }

  const reply = await model.complete({ system: CHIEF_SYSTEM, user: turnInput(view.lines, events), tools: true });
  const out = [
    ...(reply.text.trim() ? [entryFor("chief", reply.text)] : []),
    ...reply.spawns.map((s) => entryFor(`chief spawned ${s.name}`, s.prompt)),
  ];
  if (out.length > 0) {
    const noted = await memory.note(out, `turn:${turnId}:out`);
    if ("error" in noted) throw new Error(`reply refused by memory: ${noted.error}`);
  }

  for (let i = 0; i < SPARE_NAPS; i++) {
    view = await memory.view();
    if (!(await napOnce(memory, model, view))) break;
    naps++;
  }
  return { reply: reply.text, spawns: reply.spawns, naps };
}

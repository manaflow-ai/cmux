import { type Block, blockId, cover, parseBlock, pending, pendingCount } from "./blocks.ts";
import type { Entry, Knob, MemoryStorage } from "./storage.ts";
import { isRealDate, plural, pyStrip, utf8Length } from "./text.ts";

/**
 * One memory with OptMem's behavior (github.com/VictorTaelin/OptMem `memo`,
 * checked against it by the conformance vectors): an append-only log, a
 * summary tree built in order, and the wake view whose detail decays with age.
 *
 * Every command answers in memo's own words, because those words are the
 * prompt the agent reads. Failures throw MemoryError with memo's message.
 */

export const KNOBS: Readonly<Record<Knob, readonly [number, string]>> = {
  WAKE_LINES: [96, "the memory context: how many lines wake prints"],
  ENTRY_CHARS: [280, "the longest one memory may be, in bytes"],
  PART_CHARS: [20000, "output paging: largest part, in bytes"],
  PART_LINES: [500, "output paging: largest part, in lines"],
};
const KNOB_NAMES = Object.keys(KNOBS) as Array<Knob>;

/** Largest ENTRY_CHARS the reference's fixed-width records allow; kept so both agree. */
export const ENTRY_CHARS_MAX = 280;

/** Blocks up to this many entries are compressed from raw entries; larger ones from their halves. */
export const RAW_MAX = 16;

export class MemoryError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "MemoryError";
  }
}

export interface Output {
  readonly stdout: string;
  /** 0, or 1 when the command printed and still failed (wake that needs a nap first). */
  readonly code: 0 | 1;
}

export interface MemoryOptions {
  /** How commands name the tool in their hints ("Run: memo nap ..."). */
  readonly tool?: string;
  /** Today's date, YYYY-MM-DD, in the owner's time zone. */
  readonly today: () => string;
}

const die = (message: string): never => {
  throw new MemoryError(message);
};

const ok = (lines: Array<string>): Output => ({ stdout: lines.length ? `${lines.join("\n")}\n` : "", code: 0 });

export class Memory {
  private readonly tool: string;
  get toolName() {
    return this.tool;
  }
  private readonly today: () => string;

  constructor(
    readonly storage: MemoryStorage,
    options: MemoryOptions,
  ) {
    this.tool = options.tool ?? "memo";
    this.today = options.today;
  }

  knob(k: Knob): number {
    return this.storage.overrides()[k] ?? KNOBS[k][0];
  }

  // ---------------------------------------------------------------- reads

  /** Summary of block [lo, hi), or undefined while it is not built. */
  summary([lo, hi]: Block): string | undefined {
    const size = hi - lo;
    const k = lo / size;
    return k < this.storage.built(size) ? this.storage.node(size, k) : undefined;
  }

  private entry(n: number): Entry {
    const e = this.storage.entries(n, n + 1)[0];
    if (!e) throw new Error(`entry ${n} is missing`);
    return e;
  }

  private builtOf = (size: number) => this.storage.built(size);

  /** The next block to compress for a log of T entries, if any. */
  nextBlock(T = this.storage.length()): Block | undefined {
    return pending(T, this.builtOf, 1)[0];
  }

  pendingCount(T = this.storage.length()): number {
    return pendingCount(T, this.builtOf);
  }

  /** What the agent compresses for `block`: raw entries, or the two half summaries. */
  napInput([lo, hi]: Block): Array<string> {
    if (hi - lo <= RAW_MAX) return this.storage.entries(lo, hi).map((e) => `#${e.n} ${e.date} ${e.text}`);
    const mid = (lo + hi) / 2;
    return (
      [
        [lo, mid],
        [mid, hi],
      ] as Array<Block>
    ).map((half) => {
      const s = this.summary(half);
      if (s === undefined) die(`The summary of #${blockId(half)} is blank. Run: ${this.tool} forget ${blockId(half)}`);
      return `#${blockId(half)} ${s}`;
    });
  }

  napPrompt(block: Block, left: number): string {
    const body = this.napInput(block)
      .map((l) => `  ${l}`)
      .join("\n");
    const tail =
      left === 0 ? "" : `\n${left === 1 ? "1 compression remains" : `${left} compressions remain`} after this one.`;
    const id = blockId(block);
    return (
      `Compress memories #${id} into one line of at most ${this.knob("ENTRY_CHARS")} bytes.\n` +
      "Keep what has lasting effect, drop what does not. Invent nothing.\n\n" +
      `${body}\n${tail}\n` +
      `Run: ${this.tool} nap ${id} "<your line>"`
    );
  }

  nextNap(T = this.storage.length()): string | undefined {
    const block = this.nextBlock(T);
    return block && this.napPrompt(block, this.pendingCount(T) - 1);
  }

  /**
   * The wake lines as of T, oldest first, or the block that must be compressed
   * before they can be written.
   */
  coverLines(T = this.storage.length()): { lines: Array<string> } | { missing: Block } {
    const lines: Array<string> = [];
    for (const block of cover(T, this.knob("WAKE_LINES"))) {
      const [lo, hi] = block;
      if (hi - lo === 1) {
        const e = this.entry(lo);
        lines.push(`#${e.n} ${e.date} ${e.text}`);
        continue;
      }
      const s = this.summary(block);
      if (s === undefined) return { missing: block };
      lines.push(`#${blockId(block)} ${s}`);
    }
    return { lines };
  }

  /** Splits a document into parts that survive any harness's output cap. */
  paginate(lines: ReadonlyArray<string>): Array<Array<string>> {
    const parts: Array<Array<string>> = [];
    let cur: Array<string> = [];
    let size = 0;
    for (const line of lines) {
      const n = utf8Length(line) + 1;
      if (cur.length > 0 && (cur.length >= this.knob("PART_LINES") || size + n > this.knob("PART_CHARS"))) {
        parts.push(cur);
        cur = [];
        size = 0;
      }
      cur.push(line);
      size += n;
    }
    if (cur.length > 0) parts.push(cur);
    return parts;
  }

  // ---------------------------------------------------------------- commands

  /** Validates one memory line; returns it stripped. */
  check(text: string): string {
    const t = pyStrip(text);
    if (!t) die("Empty. A memory is one line of text.");
    if (t.includes("\n") || t.includes("\r")) {
      die(`${t.split("\n").length} lines. A memory is one line: merge them, or note them separately.`);
    }
    const n = utf8Length(t);
    const max = this.knob("ENTRY_CHARS");
    if (n > max) die(`Too long: ${n} bytes, limit ${max}. Accented characters cost 2 bytes. Compress it further.`);
    return t;
  }

  private block(id: string): Block {
    const b = parseBlock(id);
    if (b === "not_an_id") return die(`'${id}' is not a block id. Copy it from the prompt.`);
    if (b === "not_a_block") return die(`${id} is not a block. Copy the id printed by wake, like 16-31.`);
    return b;
  }

  wake(args: ReadonlyArray<string> = []): Output {
    const now = this.storage.length();
    let k = 1;
    let T = now;
    if (args.length > 0) {
      if (args.length > 2 || !args.every((a) => /^\d+$/.test(a))) die(`usage: ${this.tool} wake [part [T]]`);
      k = Number(args[0]);
      if (args.length === 2) {
        T = Number(args[1]);
        if (T > now) die(`T=${T}, but the log holds ${plural(now, "memory")}. Run: ${this.tool} wake`);
      }
    }
    if (T === 0)
      return ok([`No memories yet. Record the first with: ${this.tool} note "<one line>"`, "You are awake."]);
    const view = this.coverLines(T);
    if ("missing" in view) {
      const nap = this.nextNap(T);
      if (nap === undefined)
        return die(
          `The summary of #${blockId(view.missing)} is blank. Run: ${this.tool} forget ${blockId(view.missing)}`,
        );
      const head =
        `Cannot wake: the memory context needs #${blockId(view.missing)}, which is not compressed yet.\n` +
        `Do the ${plural(this.pendingCount(T), "compression")} below, then run ${this.tool} wake again.\n`;
      return { stdout: `${head}\n${nap}\n`, code: 1 };
    }
    const parts = this.paginate(view.lines);
    if (k < 1 || k > parts.length)
      die(`No part ${k}: the memory has ${plural(parts.length, "part")}. Run: ${this.tool} wake`);
    const out: Array<string> = [];
    if (parts.length > 1) out.push(`Your memory, part ${k} of ${parts.length}, oldest first (${plural(T, "memory")}).`);
    out.push(parts[k - 1]!.join("\n"));
    if (k < parts.length) {
      out.push(`Not awake yet. Run: ${this.tool} wake ${k + 1} ${T}`);
    } else {
      out.push("You are awake.");
      const nap = this.nextNap(T);
      if (nap !== undefined) out.push(`\n${nap}`);
    }
    return ok(out);
  }

  /** Appends one memory. Returns its id with memo's output. */
  note(args: ReadonlyArray<string>): Output & { readonly id: number } {
    if (args.length !== 1) die(`usage: ${this.tool} note "<one line, at most ${this.knob("ENTRY_CHARS")} bytes>"`);
    const text = this.check(args[0]!);
    const id = this.storage.append([{ date: this.today(), text }]);
    const out = [`Saved as #${id}.`];
    const nap = this.nextNap(id + 1);
    if (nap !== undefined) out.push(`\n${nap}`);
    return { ...ok(out), id };
  }

  nap(args: ReadonlyArray<string> = []): Output {
    const T = this.storage.length();
    const out: Array<string> = [];
    const said = args.length > 0;
    if (said) {
      if (args.length !== 2) die(`usage: ${this.tool} nap <lo>-<hi> "<one line>"`);
      const block = this.block(args[0]!);
      const next = this.nextBlock(T);
      if (!next) return ok(["Nothing left to compress."]);
      const id = blockId(block);
      if (block[0] !== next[0] || block[1] !== next[1]) {
        if (this.summary(block) !== undefined) out.push(`${id} is already settled.`);
        else
          die(
            `Wrong block: ${args[0]}. Blocks are built in order; the next is ${blockId(next)}. Run: ${this.tool} nap`,
          );
      } else {
        const text = this.check(args[1]!);
        const size = block[1] - block[0];
        this.storage.putNode(size, block[0] / size, text);
        out.push(`${id} saved.`);
      }
    }
    const nap = this.nextNap(T);
    if (nap === undefined) return ok([...out, "Nothing left to compress."]);
    out.push(`${said ? "\n" : ""}${nap}`);
    return ok(out);
  }

  /**
   * Drops a summary and every summary built on it (each level is cut back to
   * the block that contains `lo`); the log is untouched.
   */
  forget(args: ReadonlyArray<string>): Output {
    if (args.length !== 1) die(`usage: ${this.tool} forget <lo>-<hi>`);
    const [lo, hi] = this.block(args[0]!);
    const gone: Array<Block> = [];
    for (let size = hi - lo; size <= this.storage.length(); size *= 2) {
      const k = Math.floor(lo / size);
      const n = this.storage.built(size);
      if (n > k) {
        for (let i = k; i < n; i++) gone.push([i * size, (i + 1) * size]);
        this.storage.truncate(size, k);
      }
    }
    if (gone.length === 0) die(`No summary at ${args[0]}.`);
    return ok([`Forgot ${plural(gone.length, "summary")}, from ${blockId(gone[0]!)} up. Run: ${this.tool} nap`]);
  }

  recall(args: ReadonlyArray<string>): Output {
    if (args.length !== 1) die(`usage: ${this.tool} recall <regex>`);
    let pattern: RegExp;
    try {
      pattern = new RegExp(args[0]!, "iu");
    } catch {
      try {
        pattern = new RegExp(args[0]!, "i");
      } catch (e) {
        return die(`bad regex: ${(e as Error).message}`);
      }
    }
    // Keep only the newest matches that fit one part: a vague pattern matches everything.
    const cap = this.knob("PART_CHARS");
    const out: Array<string> = [];
    let head = 0;
    let size = 0;
    let hits = 0;
    for (const e of this.storage.scan()) {
      const line = `#${e.n} ${e.date} ${e.text}`;
      if (!pattern.test(line)) continue;
      hits++;
      out.push(line);
      size += utf8Length(line) + 1;
      while (size > cap) size -= utf8Length(out[head++]!) + 1;
    }
    if (hits === 0) return ok(["No match."]);
    const kept = out.slice(head);
    return ok([
      kept.join("\n"),
      kept.length < hits
        ? `Newest ${kept.length} of ${plural(hits, "match")}. Narrow the regex.`
        : `${plural(hits, "match")}.`,
    ]);
  }

  zoom(args: ReadonlyArray<string>): Output {
    if (args.length !== 1) die(`usage: ${this.tool} zoom <lo>-<hi>   # a block id, as wake prints them`);
    const [lo, hi] = this.block(args[0]!);
    const T = this.storage.length();
    if (lo >= T) die(`#${args[0]} is beyond the memory: it holds ${plural(T, "memory")}. Run: ${this.tool} wake`);
    const mid = (lo + hi) / 2;
    const out: Array<string> = [];
    for (const half of [
      [lo, mid],
      [mid, hi],
    ] as Array<Block>) {
      if (half[0] >= T) continue;
      if (half[1] - half[0] === 1) {
        const e = this.entry(half[0]);
        out.push(`#${e.n} ${e.date} ${e.text}`);
      } else {
        out.push(`#${blockId(half)} ${this.summary(half) ?? "not compressed yet"}`);
      }
    }
    return ok(out);
  }

  /** Shows the knobs, or changes them (`NAME=VALUE`, empty value = default). Nothing is recomputed. */
  config(args: ReadonlyArray<string> = []): Output {
    const over = this.storage.overrides();
    for (const a of args) {
      const eq = a.indexOf("=");
      const k = pyStrip(eq < 0 ? a : a.slice(0, eq)).toUpperCase() as Knob;
      if (eq < 0 || !(k in KNOBS))
        die(`usage: ${this.tool} config [NAME=VALUE ...]   # NAME one of ${KNOB_NAMES.join(", ")}`);
      const v = pyStrip(a.slice(eq + 1));
      if (v) over[k] = knobValue(k, v);
      else delete over[k];
    }
    if (args.length > 0) this.storage.setOverrides(over);
    return ok(
      KNOB_NAMES.map((k) => {
        const [dflt, what] = KNOBS[k];
        const value = String(over[k] ?? dflt);
        return `${k.padEnd(12)} ${value.padEnd(7)} ${what}${over[k] === undefined ? "" : ` (default ${dflt})`}`;
      }),
    );
  }

  /**
   * Bulk-loads dated memories, one `YYYY-MM-DD <text>` per line (bootstrap).
   * `name` is how errors refer to the source.
   */
  import(source: string, name: string): Output {
    const lines = source.split(/\r\n|\r|\n/);
    if (lines.at(-1) === "") lines.pop();
    const T = this.storage.length();
    let last = T > 0 ? this.entry(T - 1).date : "0000-00-00";
    const items: Array<{ date: string; text: string }> = [];
    const max = this.knob("ENTRY_CHARS");
    lines.forEach((line, index) => {
      const i = index + 1;
      if (!pyStrip(line)) return;
      const sp = line.indexOf(" ");
      const date = sp < 0 ? line : line.slice(0, sp);
      const rest = sp < 0 ? "" : line.slice(sp + 1);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) die(`line ${i}: expected 'YYYY-MM-DD <text>', got: ${line}`);
      if (!isRealDate(date)) die(`line ${i}: ${date} is not a real date.`);
      if (date < last) die(`line ${i}: date ${date} precedes the previous memory (${last}).`);
      const text = pyStrip(rest);
      if (!text || utf8Length(text) > max) die(`line ${i}: ${utf8Length(text)} bytes, limit ${max}.`);
      items.push({ date, text });
      last = date;
    });
    if (items.length === 0) die(`${name} has no memories.`);
    const base = this.storage.append(items);
    const out = [`Imported ${plural(items.length, "memory")}, #${base} to #${base + items.length - 1}.`];
    const n = this.pendingCount();
    if (n > 0) out.push(`${plural(n, "compression")} pending. Run: ${this.tool} nap`);
    return ok(out);
  }
}

function knobValue(k: Knob, v: string): number {
  if (!/^\d+$/.test(v) || Number(v) < 1) die(`${k} must be a positive whole number, not '${v}'.`);
  if (k === "ENTRY_CHARS" && Number(v) > ENTRY_CHARS_MAX) {
    die(`ENTRY_CHARS is at most ${ENTRY_CHARS_MAX}: a memory has to fit the fixed-width records.`);
  }
  return Number(v);
}

/** Runs one memo command line (argv without the tool name), as the CLI would. */
export function run(
  memory: Memory,
  argv: ReadonlyArray<string>,
  files: Readonly<Record<string, string>> = {},
): { stdout: string; stderr: string; code: number } {
  const [cmd, ...args] = argv;
  try {
    let out: Output;
    switch (cmd) {
      case "wake":
        out = memory.wake(args);
        break;
      case "note":
        out = memory.note(args);
        break;
      case "nap":
        out = memory.nap(args);
        break;
      case "recall":
        out = memory.recall(args);
        break;
      case "zoom":
        out = memory.zoom(args);
        break;
      case "forget":
        out = memory.forget(args);
        break;
      case "config":
        out = memory.config(args);
        break;
      case "import": {
        if (args.length !== 1) die(`usage: ${memory.toolName} import <file>   # lines of 'YYYY-MM-DD <text>'`);
        const source = files[args[0]!];
        if (source === undefined) die(`${args[0]}: No such file or directory.`);
        out = memory.import(source!, args[0]!);
        break;
      }
      default:
        return { stdout: "", stderr: `No such command: ${cmd}\n`, code: 1 };
    }
    return { stdout: out.stdout, stderr: "", code: out.code };
  } catch (e) {
    if (e instanceof MemoryError) return { stdout: "", stderr: `${e.message}\n`, code: 1 };
    throw e;
  }
}

import { ArrayMemoryStore, decompose, key, type Range, toLines, wake, wakeCover, zoom } from "../memory.ts";
import { Core, type Effect, type Input } from "./core.ts";
import type { HostStateData } from "./state.ts";

// The shared behavior corpus, format `cmux-chief-corpus/1`
// (plans/cmux-next/chief-mac.md section 4), written by
// conformance/generate.ts. Each case starts a core from a durable state,
// feeds inputs with their time (ms since the epoch), and expects the exact
// effects and the durable state after. `log` effects are not compared (their
// text is diagnostics). Memory cases call one pure memory function. The Rust
// core runs the same file (cmux-chief tests/corpus.rs).

export const CORPUS_FORMAT = "cmux-chief-corpus/1";

export interface CorpusStep {
  now: number;
  input: Input;
  effects: Effect[];
}

export interface CorpusCase {
  name: string;
  state: HostStateData;
  steps: CorpusStep[];
  state_after: HostStateData;
}

export type MemoryFunction = "to_lines" | "decompose" | "wake_cover" | "wake" | "zoom";

export interface MemoryCase {
  name: string;
  fn: MemoryFunction;
  args: Record<string, unknown>;
  result: unknown;
}

export interface Corpus {
  format: string;
  notes?: string[];
  cases: CorpusCase[];
  memory: MemoryCase[];
}

/** A JSON value with undefined fields dropped (what the wire carries). */
export const plain = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

/** Order-sensitive for arrays, order-free for object keys (serde_json Value equality). */
export function jsonEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) {
    const other = b as unknown[];
    return a.length === other.length && a.every((value, index) => jsonEqual(value, other[index]));
  }
  const left = a as Record<string, unknown>;
  const right = b as Record<string, unknown>;
  const keys = Object.keys(left);
  if (keys.length !== Object.keys(right).length) return false;
  return keys.every((k) => Object.hasOwn(right, k) && jsonEqual(left[k], right[k]));
}

const withoutLogs = (effects: Effect[]) => plain(effects.filter((effect) => effect.kind !== "log"));

/** Runs one case; the error names the first step that differs. */
export function runCase(c: CorpusCase): string | undefined {
  const core = new Core(c.state);
  for (const [index, step] of c.steps.entries()) {
    const got = withoutLogs(core.step(plain(step.input), step.now));
    const want = withoutLogs(step.effects);
    if (!jsonEqual(got, want))
      return `${c.name}: step ${index}: effects differ\n  want ${JSON.stringify(want)}\n  got  ${JSON.stringify(got)}`;
  }
  const got = plain(core.state);
  if (!jsonEqual(got, plain(c.state_after)))
    return `${c.name}: state_after differs\n  want ${JSON.stringify(c.state_after)}\n  got  ${JSON.stringify(got)}`;
  return undefined;
}

function parseRange(text: string): Range | undefined {
  const match = /^(\d+)-(\d+)$/.exec(text);
  if (!match) return undefined;
  const range = { lo: Number(match[1]), hi: Number(match[2]) };
  return range.lo <= range.hi ? range : undefined;
}

function storeOf(args: Record<string, unknown>): ArrayMemoryStore {
  const store = new ArrayMemoryStore();
  store.lines = [...((args.lines as string[] | undefined) ?? [])];
  for (const [k, summary] of Object.entries((args.nodes as Record<string, string> | undefined) ?? {}))
    store.nodes.set(k, summary);
  return store;
}

/** The result of one memory function, as the corpus records it (ranges as `lo-hi`). */
export async function memoryResult(fn: MemoryFunction, args: Record<string, unknown>): Promise<unknown> {
  const keys = (ranges: Range[]) => ranges.map(key);
  switch (fn) {
    case "to_lines":
      return toLines(args.text as string);
    case "decompose":
      return keys(decompose(args.length as number));
    case "wake_cover":
      return keys(wakeCover(args.length as number, args.budget as number));
    case "wake": {
      const view = await wake(storeOf(args), args.budget as number);
      return { text: view.text, missing: keys(view.missing) };
    }
    case "zoom": {
      const range = parseRange(args.range as string);
      if (!range) throw new Error(`bad range ${String(args.range)}`);
      return zoom(storeOf(args), range);
    }
  }
}

export async function runMemoryCase(c: MemoryCase): Promise<string | undefined> {
  const got = plain(await memoryResult(c.fn, c.args));
  return jsonEqual(got, c.result) ? undefined : `${c.name}: want ${JSON.stringify(c.result)} got ${JSON.stringify(got)}`;
}

/** Runs a whole corpus; returns every failure. */
export async function runCorpus(corpus: Corpus): Promise<string[]> {
  if (corpus.format !== CORPUS_FORMAT) return [`format ${corpus.format} is not ${CORPUS_FORMAT}`];
  const failures: string[] = [];
  for (const c of corpus.cases) {
    const failure = runCase(c);
    if (failure) failures.push(failure);
  }
  for (const c of corpus.memory) {
    const failure = await runMemoryCase(c);
    if (failure) failures.push(failure);
  }
  return failures;
}

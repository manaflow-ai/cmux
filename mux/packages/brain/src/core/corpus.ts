import { admitHarness, remoteAutoApprove, spawnFloor, turnPolicy } from "./policy.ts";
import { ArrayMemoryStore, decompose, key, type Range, toLines, wake, wakeCover, zoom } from "../memory.ts";
import { Core, type Effect, type Input } from "./core.ts";
import type { HostStateData } from "./state.ts";
import { plain } from "./text.ts";
import { AGENT_MUX, USER_LOCAL } from "./conversation.ts";
import { CHIEF_CONVERSATION_TITLE, CHIEF_DISPLAY_NAME, DEFAULT_CONVERSATION_KEY, MUX_SESSION_NAME, selectChiefConversation } from "./rules.ts";
import type { Summary } from "./conversation.ts";

export { plain };

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
  /** The input as a JSON value. Absent when `input_text` is set. */
  input?: Input;
  /**
   * The input as wire text, parsed by each core's own JSON reader: it pins
   * number text a JSON value cannot carry (`1.0` is the integer 1 in both
   * cores; JSON has one number type, so only the value counts).
   */
  input_text?: string;
  effects: Effect[];
}

export interface CorpusCase {
  name: string;
  state: HostStateData;
  steps: CorpusStep[];
  state_after: HostStateData;
}

export type MemoryFunction = "to_lines" | "decompose" | "wake_cover" | "wake" | "zoom";

export interface SelectionCase {
  name: string;
  conversations: Summary[];
  selected: string | null;
}

export interface MemoryCase {
  name: string;
  fn: MemoryFunction;
  args: Record<string, unknown>;
  result: unknown;
}

export type PolicyFunction = "remote_auto_approve" | "turn_policy" | "spawn_floor" | "harness_admit";

/** One approval-policy or harness-routing decision (policy.ts / cmux_chief::policy). */
export interface PolicyCase {
  name: string;
  fn: PolicyFunction;
  args: Record<string, unknown>;
  result: unknown;
}

export interface Corpus {
  format: string;
  notes?: string[];
  /**
   * The wire constants both hosts use (rules.ts / rules.rs): the default
   * conversation's create key, title and Chief name (the app's Home Chief
   * conversation, decision c), the session name and the participant ids.
   */
  rules?: Record<string, string>;
  /** The Chief conversation rule (rules.ts selectChiefConversation): a list and the id it selects (null: create home-chief). */
  selection?: SelectionCase[];
  /** Approval policy and harness routing (policy.ts): the same decision in every brain. */
  policy?: PolicyCase[];
  cases: CorpusCase[];
  memory: MemoryCase[];
}


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
    let input = step.input;
    if (step.input_text !== undefined) {
      try {
        input = JSON.parse(step.input_text) as Input;
      } catch (error) {
        return `${c.name}: step ${index}: input_text: ${String(error)}`;
      }
    }
    if (input === undefined) return `${c.name}: step ${index}: no input`;
    const got = withoutLogs(core.step(plain(input), step.now));
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

/** The result of one policy function, as the corpus records it. */
export function policyResult(fn: PolicyFunction, args: Record<string, unknown>): unknown {
  switch (fn) {
    case "remote_auto_approve":
      return remoteAutoApprove(args.settings);
    case "turn_policy":
      return turnPolicy(args.remote as boolean, args.auto_approve as boolean, args.configured as string);
    case "spawn_floor":
      return spawnFloor(args.auto_approve as boolean, args.turn_ask as boolean, args.ask_child_live as boolean, args.ask_subagent_live as boolean);
    case "harness_admit":
      return admitHarness(args.answer, args.requested as string);
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
  for (const c of corpus.selection ?? []) {
    const got = selectChiefConversation(c.conversations)?.id ?? null;
    if (got !== c.selected) failures.push(`${c.name}: selects ${got}, want ${c.selected}`);
  }
  if (!jsonEqual(corpus.rules, corpusRules())) failures.push(`rules differ: want ${JSON.stringify(corpus.rules)} got ${JSON.stringify(corpusRules())}`);
  for (const c of corpus.cases) {
    const failure = runCase(c);
    if (failure) failures.push(failure);
  }
  for (const c of corpus.memory) {
    const failure = await runMemoryCase(c);
    if (failure) failures.push(failure);
  }
  for (const c of corpus.policy ?? []) {
    const got = plain(policyResult(c.fn, c.args));
    if (!jsonEqual(got, c.result)) failures.push(`${c.name}: want ${JSON.stringify(c.result)} got ${JSON.stringify(got)}`);
  }
  return failures;
}

/** The wire constants the corpus pins (`rules`), from rules.ts. */
export function corpusRules(): Record<string, string> {
  return {
    agent_mux: AGENT_MUX,
    chief_conversation_title: CHIEF_CONVERSATION_TITLE,
    chief_display_name: CHIEF_DISPLAY_NAME,
    default_conversation_key: DEFAULT_CONVERSATION_KEY,
    mux_session_name: MUX_SESSION_NAME,
    user_local: USER_LOCAL,
  };
}

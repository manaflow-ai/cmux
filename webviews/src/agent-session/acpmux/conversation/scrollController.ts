// The transcript's one scroll writer (cmuxterm-hq docs/design/agent-transcript-clean-slate.md,
// invariant 1). Every write to the chat scroller's offset (follow, find, jump, fold, older pages,
// the minimaps, keys) goes through here, and the `cmux-perf/transcript-scroll-writer` lint refuses
// `scrollTop =`, `scrollTo`, `scrollBy` and `scrollIntoView` anywhere else in the transcript's files.
//
// Today a write lands at once, exactly as the callers' own writes did, so the list behaves the same;
// what one owner adds is a name on every write and the one place the anchored list (step 4) turns
// into "read the anchor, change the DOM, measure, restore the anchor".
//
// With `globalThis.__cmuxScrollTrace` set to an array (the replay bench sets it), each write that
// moves the offset pushes `{ writer, from, to, at }`, capped at TRACE_CAP entries.

export type ScrollWriter =
  | "follow"
  | "open"
  | "jump"
  | "glide"
  | "find"
  | "reveal"
  | "older"
  | "lift"
  | "fold"
  | "momentum"
  | "wheel"
  | "keys"
  | "minimap"
  | "anchor"
  | "steps";

type Node = Pick<HTMLElement, "scrollTop">;
type Trace = { writer: ScrollWriter; from: number; to: number; at: number }[];

const TRACE_CAP = 20_000;

const traceLog = () => (globalThis as { __cmuxScrollTrace?: Trace }).__cmuxScrollTrace;

/** Writes the scroller's offset. It reads nothing back unless tracing, so it forces no layout. */
export function writeScrollTop(node: Node, top: number, writer: ScrollWriter): void {
  const log = traceLog();
  if (!Array.isArray(log) || log.length >= TRACE_CAP) {
    node.scrollTop = top;
    return;
  }
  const from = node.scrollTop;
  node.scrollTop = top;
  const to = node.scrollTop;
  if (Math.abs(to - from) >= 0.01) log.push({ writer, from, to, at: performance.now() });
}

/** Moves the scroller's offset by `delta` px. */
export function writeScrollBy(node: Node, delta: number, writer: ScrollWriter): void {
  writeScrollTop(node, node.scrollTop + delta, writer);
}

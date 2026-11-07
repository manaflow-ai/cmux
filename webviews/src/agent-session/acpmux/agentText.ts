// Whether pasted text reads as another agent's output: a handoff, receipt or status report with no
// sender format around it (ask-fa4c523fa8; Leo, 2026-11-06: "it should be automatically
// attributable, so it doesn't just pass off as one of my messages"). The same deterministic
// signals as acpmux's `agent_text.rs`, which marks the agent's view and the record: a `From NAME:`
// header, a `Trace-ID:` line, a generated-with or co-author footer, an agent session line, a review
// receipt, a batched message's `[message N of M] from` line or a `Handoff` heading. The composer
// reads them to keep such a paste as its own block (composer/pasteMarks.ts), and the bubble to name
// its sender (PromptText.tsx PasteChip) before acpmux's echo arrives, so nothing changes when it does.

/// The characters read from the start of a text: headers sit there.
export const HEAD_CHARS = 16 * 1024;
/// The characters read from its end: footers sit there.
export const TAIL_CHARS = 4 * 1024;

export type AgentText = {
  /// The sender a header or footer names (`From Codex:`, `Generated with [Codex]`).
  from?: string;
  /// Each signal found, at most once each.
  signals: string[];
};

const HEADER =
  /^\s*(?:\*\*)?(?:from|message from|reply from|handoff from|report from|update from)\s+([A-Za-z][\w .@/()-]{0,47}?)(?:\*\*)?\s*:(?:\*\*)?(?:\s|$)/i;
const TRACE_ID = /^\s*trace-id:\s*\S+/i;
const GENERATED = /generated (?:with|by) \[?([A-Za-z][\w .-]{0,31}?)\]?(?:\(|\s*$)/i;
const CO_AUTHOR = /^\s*co-authored-by:\s*\S/i;
const SESSION_LINE = /^\s*(?:agent session|author-agent|agent-id):\s*\S/i;
const RECEIPT = /^\s*(?:review \([^)]{1,80}\)|verdict)\s*:\s*(?:ship|block)\b/i;
const BATCH_LINE = /^\s*\[message \d+ of \d+\] from (\S.{0,63})$/;
const HANDOFF = /^\s*#{1,4}\s*handoff\b/i;

/// First words of a `From X:` line a person writes, not a sender's name.
const NOT_NAMES = new Set([
  "now",
  "here",
  "there",
  "then",
  "today",
  "tomorrow",
  "yesterday",
  "the",
  "my",
  "your",
  "our",
  "this",
  "that",
  "these",
  "those",
  "what",
  "where",
  "me",
  "us",
  "him",
  "her",
  "them",
  "it",
  "a",
  "an",
  "time",
  "experience",
]);

/// The signals in `text`, reading only its head and tail, so a megabyte paste costs what a page does.
export function agentText(text: string): AgentText {
  const found: AgentText = { signals: [] };
  const head = text.length > HEAD_CHARS + TAIL_CHARS ? text.slice(0, HEAD_CHARS) : text;
  // The tail from its first whole line on.
  const tail =
    text.length > HEAD_CHARS + TAIL_CHARS ? text.slice(text.length - TAIL_CHARS).replace(/^[^\n]*\n?/, "") : "";
  for (const line of [...head.split("\n"), ...(tail ? tail.split("\n") : [])]) scan(line, found);
  return found;
}

function scan(line: string, found: AgentText) {
  const add = (signal: string) => {
    if (!found.signals.includes(signal)) found.signals.push(signal);
  };
  const named = (name: string) => {
    found.from ??= name.trim();
  };
  const header = HEADER.exec(line)?.[1]?.trim();
  if (header) {
    const lower = header.toLowerCase();
    if (!NOT_NAMES.has(lower.split(/\s+/)[0] ?? "") && !NOT_NAMES.has(lower)) {
      add("header");
      named(header);
    }
  }
  if (TRACE_ID.test(line)) add("trace");
  const generated = GENERATED.exec(line)?.[1];
  if (generated) {
    add("generated");
    named(generated);
  }
  if (CO_AUTHOR.test(line)) add("coauthor");
  if (SESSION_LINE.test(line)) add("session");
  if (RECEIPT.test(line)) add("receipt");
  const batch = BATCH_LINE.exec(line)?.[1];
  if (batch) {
    add("relayed");
    named(batch);
  }
  if (HANDOFF.test(line)) add("handoff");
}

/// Whether `text` reads as another agent's output.
export const readsAsAgent = (text: string) => agentText(text).signals.length > 0;

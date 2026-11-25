// The bubble-integrity checker (docs/design/chat-stream-scenarios.md, "Detectors"): rules on the rows the pane
// draws that hold for any chat, so the same checks run on a simulated scenario at every step and on a real
// recorded session (scripts/chat-sim.ts --replay DIR --integrity, Leo's NIGHTLY sessions).
//
// Leo, 2026-11-22: "there are probably more bullshit scenarios. we need to map them all out and note what
// expected behaviours are for all." The rules come from the bugs he found by hand that day: one reply drawn as two
// bubbles cut mid-bold with a "Worked for" fold between them (images/1158.png), a reply's paragraphs drawn twice
// (1157.png), and an ended turn still drawing an empty placeholder row (#49992).
import type { AcpmuxRow } from "../model";

export type IntegrityRule =
  /** One message, one bubble: two reply rows with nothing but a fold or header between them, of one message
   *  (same messageId) or with the first cut inside a Markdown span. */
  | "i-split-bubble"
  /** A paragraph drawn twice in one turn. */
  | "i-repeated-paragraph"
  /** A settled reply (its turn ended) whose `**`, code fence or `$$` is left open. */
  | "i-unclosed-markdown"
  /** An ended turn still draws a placeholder (typing) or live line. */
  | "i-placeholder-after-end"
  /** The text the agent sent is not the text the pane holds: a chunk lost or folded twice. */
  | "i-text-conserved";

export type IntegrityFinding = { rule: IntegrityRule; rowId: string; detail: string };

/** Rows that draw no reply text and may stand between two halves of a split reply. */
const BETWEEN = new Set(["worked", "working", "typing", "thinking", "since", "sinceDivider", "turnSummary"]);
const isReply = (row: AcpmuxRow) => row.kind === "assistant" && typeof row.text === "string" && row.text.trim() !== "";
export const opensTurn = (row: AcpmuxRow) =>
  row.kind === "user" && !(row as { steer?: unknown }).steer && row.incoming?.kind !== "hidden";

/** Text with inline and fenced code taken out, so a `**` inside code does not count. */
function prose(text: string): string {
  return text.replace(/```[\s\S]*?(```|$)/g, "").replace(/`[^`\n]*`/g, "");
}

/** The Markdown spans `text` leaves open at its end: `**`, a ``` fence, an inline backtick, `$$`. */
export function openSpans(text: string): string[] {
  const open: string[] = [];
  const fences = text.split("\n").filter((line) => /^\s*```/.test(line)).length;
  if (fences % 2 === 1) open.push("```");
  // An inline code span left open on the text's last line (fences taken out): a cut inside `code`.
  const unfenced = text.replace(/```[\s\S]*?(```|$)/g, "");
  if (((unfenced.split("\n").at(-1)!.match(/`/g) ?? []).length & 1) === 1) open.push("`");
  const outside = prose(text);
  if (((outside.match(/\*\*/g) ?? []).length & 1) === 1) open.push("**");
  if (((outside.match(/\$\$/g) ?? []).length & 1) === 1) open.push("$$");
  return open;
}

const paragraphs = (text: string) =>
  text
    .split(/\n\s*\n/)
    .map((part) => part.replace(/\s+/g, " ").trim())
    .filter((part) => part.length >= 40);

export type IntegrityInput = {
  /** The rows drawn (the turn view's rows), top to bottom. */
  rows: readonly AcpmuxRow[];
  /** The running (newest) turn has ended. */
  turnEnded: boolean;
  /** The message a reply row streamed (the reducer's `rowsOfMessage`, inverted). */
  messageOf?: (rowId: string) => string | undefined;
};

/// Checks the drawn rows; [] when every rule holds.
export function checkIntegrity({ rows, turnEnded, messageOf }: IntegrityInput): IntegrityFinding[] {
  const findings: IntegrityFinding[] = [];
  // The turns: rows from one opening row to the next. Only the newest can be running.
  const turns: AcpmuxRow[][] = [[]];
  for (const row of rows) {
    // A turn opens at a prompt, and a woken turn (no prompt) after the last one's summary.
    if (opensTurn(row) || turns.at(-1)!.at(-1)?.kind === "turnSummary") turns.push([]);
    turns.at(-1)!.push(row);
  }
  turns.forEach((turn, index) => {
    const ended = index < turns.length - 1 || turnEnded;
    let previous: AcpmuxRow | undefined;
    let between: AcpmuxRow[] = [];
    const seen = new Map<string, string>();
    for (const row of turn) {
      if (!isReply(row)) {
        // A Stop hook's line (sender "hook") sent the agent back: what it writes next answers the hook, so a
        // paragraph it says again reads as that answer, not as one paragraph drawn twice (SE-18).
        if (
          (row.incoming as { message?: { notice?: { sender?: string } } } | undefined)?.message?.notice?.sender ===
          "hook"
        )
          seen.clear();
        if (previous && BETWEEN.has(row.kind)) between.push(row);
        else previous = undefined;
        if (ended && row.kind === "typing")
          findings.push({ rule: "i-placeholder-after-end", rowId: row.id, detail: "an ended turn draws a typing row" });
        continue;
      }
      if (previous) {
        const same = messageOf && messageOf(previous.id) !== undefined && messageOf(previous.id) === messageOf(row.id);
        const cut = previous.streaming !== true ? openSpans(previous.text!) : [];
        if (same || cut.length) {
          const fold = between.find((other) => other.kind === "worked" || other.kind === "working");
          findings.push({
            rule: "i-split-bubble",
            rowId: row.id,
            detail: `${previous.id} and ${row.id} are one reply drawn as two${same ? ` (message ${messageOf!(row.id)})` : ""}${cut.length ? `, cut inside ${cut.join(" ")}` : ""}${fold ? `, with ${fold.kind} ${fold.id} between` : ""}`,
          });
        }
      }
      for (const paragraph of paragraphs(row.text!)) {
        const first = seen.get(paragraph);
        if (first !== undefined)
          findings.push({
            rule: "i-repeated-paragraph",
            rowId: row.id,
            detail: `"${paragraph.slice(0, 60)}" drawn again (first in ${first})`,
          });
        else seen.set(paragraph, row.id);
      }
      if (ended && row.streaming !== true) {
        const open = openSpans(row.text!);
        if (open.length)
          findings.push({
            rule: "i-unclosed-markdown",
            rowId: row.id,
            detail: `settled reply leaves ${open.join(" ")} open`,
          });
      }
      previous = row;
      between = [];
    }
  });
  return findings;
}

/// The reply text the agent sent, in order (every `agent_message_chunk`, less messages acpmux superseded), against
/// the text the reducer's rows hold: a chunk lost or folded twice shows as a difference.
export function checkTextConserved(
  events: readonly { kind: string; msg: any }[],
  rawRows: readonly AcpmuxRow[],
): IntegrityFinding[] {
  const superseded = new Set(
    events.filter((event) => event.kind === "message_superseded").map((event) => String(event.msg?.oldMessageId)),
  );
  const sent = events
    .filter((event) => event.kind === "agent_message_chunk")
    .filter((event) => !superseded.has(String(event.msg?.params?.update?.messageId)))
    .map((event) => String(event.msg?.params?.update?.content?.text ?? ""))
    .join("");
  const held = rawRows
    .filter((row) => row.kind === "assistant")
    .map((row) => row.text ?? "")
    .join("");
  const squash = (value: string) => value.replace(/\s+/g, "");
  if (squash(sent) === squash(held)) return [];
  const [a, b] = [squash(sent), squash(held)];
  let at = 0;
  while (at < a.length && a[at] === b[at]) at += 1;
  return [
    {
      rule: "i-text-conserved",
      rowId: "",
      detail: `sent ${a.length} chars, rows hold ${b.length}; first difference at ${at}: sent "${a.slice(at, at + 40)}" held "${b.slice(at, at + 40)}"`,
    },
  ];
}

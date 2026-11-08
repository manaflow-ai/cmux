// Merge readiness: what stands between this pull request and a merge, read from the same gates our
// merge path enforces (leo-workspace tools/merge_hold.py and review_model.py), so the page's
// "Ready" means the land would go through and each "Blocked" line names the gate that refuses it:
// - a review from a different model family (or a person) with a SHIP receipt at the exact head;
// - no BLOCK (or other wait verdict) receipt at the head; a later SHIP does not clear one;
// - no hold: a hold label, or a body line starting "HOLD:";
// - no red check of its own: a failing check that does not also fail on the base branch;
// - no check still running;
// - into main, the person's by-name approval of the head (merge_hold's approvals file, which the
//   page cannot read, so it says what is needed);
// - and GitHub's own: not a draft, no conflict with the base.
import type { DashboardChecks, DashboardJob, LinkedPullRequest, PullRequestDetails } from "./types";

export type Family = "codex" | "claude" | "person" | "self";

/** A review receipt: the first line of a comment, `Review (<reviewer>): <VERDICT> at <full head>`. */
export interface Receipt {
  reviewer: string;
  /** The reviewer's model, when the receipt names one (`gpt-6.1-sol`). */
  model: string | null;
  family: Family | null;
  verdict: "ship" | "wait";
  /** The verdict word as written: SHIP, BLOCK, FIX, NOT SHIP, HOLD. */
  word: string;
  sha: string;
  /** Its comment's place in `details.conversation`. */
  entry: number;
  url: string | null;
  body: string;
}

export type Blocker =
  | { kind: "review"; author: Family | "mixed" | null; ships: Receipt[]; older: Receipt | null }
  | { kind: "verdict"; receipt: Receipt }
  | { kind: "hold"; label: string | null; line: string | null }
  | { kind: "red"; checks: { name: string; url?: string; job?: DashboardJob }[] }
  | { kind: "running"; count: number }
  | { kind: "main" }
  | { kind: "draft" }
  | { kind: "conflict" };

export interface Readiness {
  state: "ready" | "blocked" | "merged" | "closed" | "unknown";
  /** The SHIP that counts, when there is one. */
  ship: Receipt | null;
  blockers: Blocker[];
}

// review_model.py's families.
const CODEX = /codex|\bgpt\b|gpt-|\bsol\b|astra|router-review|next-review|openai/i;
const CLAUDE = /claude|opus|sonnet|haiku|fable|anthropic/i;
const PERSON = /\b(?:person|human|leo)\b/i;
const SUBAGENT = /subagent/i;
const MODEL = /\b(?:gpt-[0-9][\w.-]*|claude-(?:opus|sonnet|haiku)-[0-9][\w.-]*)\b/i;
const RECEIPT = /^\s*Review \(([^)\n]*)\):\s*(SHIP|BLOCK|FIX|NOT SHIP|HOLD)\b[^\n]*?\bat\s+([0-9a-f]{40})(?![0-9a-f])/i;
const REVIEWER_LINE = /^Reviewer: codex (gpt-[0-9][\w.-]*)/im;

// merge_hold.py's HOLD_LABELS and BODY_HOLD.
const HOLD_LABELS = new Set(["hold", "needs a call", "needs-a-call", "needs-decision", "do-not-merge", "do not merge"]);
const BODY_HOLD = /^[^\w\n]*(?:HOLD(?:ING)?\b(?!-\w)|[Hh][Oo][Ll][Dd](?:[Ii][Nn][Gg])?\b[*_ \t\r]*(?:[:—–]|-\s|$))/m;

/** A reviewer label's family; null when it names none. */
export function reviewerFamily(label: string): Family | null {
  if (CODEX.test(label)) return "codex";
  if (CLAUDE.test(label)) return "claude";
  if (PERSON.test(label)) return "person";
  if (SUBAGENT.test(label)) return "self";
  return null;
}

/** The author's family from the body's footer: one family, both (`mixed`), or null when it says neither. */
export function authorFamily(body: string): Family | "mixed" | null {
  const claude = /Generated with \[Claude Code\]/i.test(body);
  const codex = /Generated with \[Codex\]/i.test(body);
  if (claude && codex) return "mixed";
  return claude ? "claude" : codex ? "codex" : null;
}

/** Every receipt in the conversation, oldest first. */
export function receipts(details: PullRequestDetails): Receipt[] {
  const out: Receipt[] = [];
  details.conversation.forEach((entry, index) => {
    const match = RECEIPT.exec(entry.body);
    if (!match) return;
    const [, reviewer = "", word = "", sha = ""] = match;
    const verdict = word.toUpperCase() === "SHIP" ? "ship" : "wait";
    const model = REVIEWER_LINE.exec(entry.body)?.[1] ?? MODEL.exec(reviewer)?.[0] ?? null;
    out.push({
      reviewer: reviewer.trim(),
      model,
      family: reviewerFamily(reviewer),
      verdict,
      word: word.toUpperCase(),
      sha: sha.toLowerCase(),
      entry: index,
      url: entry.url,
      body: entry.body,
    });
  });
  return out;
}

/** Whether `receipt` is a review by someone other than the author's own family. */
function independent(receipt: Receipt, author: Family | "mixed" | null): boolean {
  if (receipt.family === null || receipt.family === "self") return false;
  if (receipt.family === "person" || author === null || author === "mixed") return true;
  return receipt.family !== author;
}

function holdOf(pr: LinkedPullRequest, body: string): Blocker | null {
  const label = (pr.labels ?? []).find((name) => HOLD_LABELS.has(name.toLowerCase())) ?? null;
  const line =
    body
      .split("\n")
      .find((each) => BODY_HOLD.test(each))
      ?.trim() ?? null;
  return label || line ? { kind: "hold", label, line } : null;
}

function redOf(pr: LinkedPullRequest, checks: DashboardChecks | null): Blocker | null {
  if (checks?.jobs.length) {
    const red = checks.jobs.filter((job) => job.state === "failed" && !job.onBase);
    return red.length ? { kind: "red", checks: red.map((job) => ({ name: job.name, url: job.url, job })) } : null;
  }
  const red = (pr.checkList ?? []).filter((check) => check.state === "failed" && !check.onBase);
  return red.length ? { kind: "red", checks: red.map((check) => ({ name: check.name, url: check.url })) } : null;
}

function runningOf(pr: LinkedPullRequest, checks: DashboardChecks | null): number {
  if (checks?.jobs.length) return checks.jobs.filter((job) => job.state === "running" || job.state === "queued").length;
  return (pr.checkList ?? []).filter((check) => check.state === "pending").length;
}

/** What stands between `pr` at `details.headCommit` and a merge. */
export function readiness(
  pr: LinkedPullRequest,
  details: PullRequestDetails | null,
  checks: DashboardChecks | null,
): Readiness {
  if (pr.state === "merged") return { state: "merged", ship: null, blockers: [] };
  if (pr.state === "closed") return { state: "closed", ship: null, blockers: [] };
  if (!details?.headCommit) return { state: "unknown", ship: null, blockers: [] };
  const head = details.headCommit.toLowerCase();
  const all = receipts(details);
  const atHead = all.filter((receipt) => receipt.sha === head);
  const author = authorFamily(details.body);
  const blockers: Blocker[] = [];
  if (pr.state === "draft") blockers.push({ kind: "draft" });
  // A wait verdict at the head refuses whatever came after it (no reviewer shopping).
  for (const receipt of atHead) if (receipt.verdict === "wait") blockers.push({ kind: "verdict", receipt });
  const ships = atHead.filter((receipt) => receipt.verdict === "ship");
  const ship = ships.find((receipt) => independent(receipt, author)) ?? null;
  if (!ship) {
    const older = [...all].reverse().find((receipt) => receipt.verdict === "ship" && receipt.sha !== head) ?? null;
    blockers.push({ kind: "review", author, ships, older });
  }
  const hold = holdOf(pr, details.body);
  if (hold) blockers.push(hold);
  const red = redOf(pr, checks);
  if (red) blockers.push(red);
  const running = runningOf(pr, checks);
  if (running) blockers.push({ kind: "running", count: running });
  if (pr.mergeable === "conflicting") blockers.push({ kind: "conflict" });
  if (pr.baseRef === "main") blockers.push({ kind: "main" });
  return { state: blockers.length ? "blocked" : "ready", ship, blockers };
}

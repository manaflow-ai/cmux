// l10n-allow-file: synthetic lane reports and inbox notices for gallery captures.
import type { AcpmuxRow } from "../model";

const SHA = "abcdef0123456789abcdef0123456789abcdef01";
const P1 = "[P1] Keep the pending reply when a connection drops so retrying does not lose the person's draft.";
const P2 =
  "[P2] Retain the sender's session identifier when a queued report is delivered so its name still opens the right chat.";

export function report(index: number, prefix: string): AcpmuxRow {
  const blocked = index === 4;
  const name = `review-${28631 + index}`;
  const reply = blocked
    ? `Review (Astra): BLOCK at ${SHA}\n${P1}\n${P2}`
    : `Review (Astra): SHIP at ${SHA}\nNo findings. The focused checks pass.`;
  const text = `lane report: turn 1 ended, idle.\nSession: synthetic-session-${index}\nLast message: ${reply}\nCommits named: ${SHA}\n(acpmux sends this when a lane ends. Answer only if it needs you.)`;
  return {
    id: `${prefix}-report-${index}`,
    version: 1,
    at: 1_800_000_000_000 + index,
    kind: "user",
    text,
    incoming: {
      kind: "message",
      message: { name, sessionId: `synthetic-session-${index}`, report: true, text, raw: `[${name}] ${text}` },
    },
  };
}
export function notice(index: number, prefix: string): AcpmuxRow {
  const sender = ["layout-review", "message-rows", "pane-tools"][index]!;
  const thread = `from:${sender}/pr:${28641 + index}`;
  const text = `New messages from other agents in 1 thread.\n- 1 new in #${28641 + index} from ${sender}: The focused checks passed; the change is ready to review. (thread ${thread})`;
  return {
    id: `${prefix}-inbox-${index}`,
    version: 1,
    at: 1_800_000_000_000 + index,
    kind: "user",
    text,
    incoming: {
      kind: "message",
      message: { name: "inbox", text, raw: `[inbox] ${text}`, noticeThreads: [{ id: thread, sender }] },
    },
  };
}

/// The screenshot-shaped notice: one harness wrapper carrying many deliveries, with no prose that
/// should survive in the transcript. The inbox gallery renders these through flattenInboxRows.
export function inboxMany(prefix: string): AcpmuxRow {
  const lines = Array.from(
    { length: 13 },
    (_, index) =>
      `- 1 new in #${29626 + index} from lane-${index}: merged #${29626 + index} (thread from:lane-${index}/pr:${29626 + index})`,
  );
  const text = ["New messages from other agents in 13 threads.", ...lines].join("\n");
  return {
    id: `${prefix}-inbox-many`,
    version: 1,
    at: 1_800_000_000_000,
    kind: "user",
    text,
    incoming: {
      kind: "message",
      message: { name: "inbox", text, raw: `[inbox] ${text}` },
    },
  };
}

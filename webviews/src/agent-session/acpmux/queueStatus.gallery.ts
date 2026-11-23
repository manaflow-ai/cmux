// l10n-allow-file: gallery fixtures (sample prompts, agent tasks and errors), not shipped UI.
// The chat's one status line after a failed turn (QueueStatusLine.tsx, queueStatus.ts) and a queued
// surge digest's row (surgeDigest.ts). Leo, 2026-11-23, on a pane that read "Retrying (1/4) after a
// capacity error" over "Paused after an error: API Error: 503 no non-exhausted claude accounts
// available; next account frees up in 10m ..." over "Held during a message surge: 29 message(s) in 23
// thread(s) need you. Routine and handled ones...": "this looks ass idk".
// The arms (queueStatus.experiment.ts) differ in hierarchy only; every arm says one state, counts down
// to the daemon's retry, keeps the raw error behind Details and draws the digest as a labelled summary.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, row, summary, user } from "../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../gallery/clock";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";
import type { AcpmuxSnapshot } from "./model";

const ERROR =
  "API Error: 503 no non-exhausted claude accounts available; next account frees up in 10m (pool: 6 accounts, 6 exhausted). Retry-After: 600";

const DIGEST = [
  "Held during a message surge: 29 message(s) in 23 thread(s) need you. Routine and handled ones stay in your inbox archive.",
  "- [pr:2210] 3 msg from grid-lane: review passed, landing it now",
  "  read: acpmux session inbox coord --thread pr:2210",
  "- [topic:rail] 2 msg from picker-lane: the rail's band now reaches the last tick",
  "  read: acpmux session inbox coord --thread topic:rail",
  "+21 more threads: acpmux session inbox coord",
].join("\n");

function agent(task: string, minutes: number): Subagent {
  return {
    id: `agent-${task.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}`,
    parent: null,
    name: "general-purpose",
    task,
    kind: "general-purpose",
    state: "running",
    background: true,
    startedAt: minutesAgo(minutes),
  };
}

const retry = (attempt = 1) => ({ attempt, of: 4, reason: "capacity", nextAt: Date.now() + 9 * 60_000 + 42_000 });

function failed(fields: {
  queue?: AcpmuxSnapshot["queue"];
  paused?: boolean;
  retrying?: boolean;
  surge?: boolean;
  error?: string;
}): AcpmuxSnapshot {
  const base = chat([
    user("Land the polish PRs once their reviews pass.", 8),
    row(SUBAGENTS, 8, {
      subagents: [agent("Review the tray columns", 7), agent("Review the header counts", 6)],
    }),
    assistant("Checking the three reviews now.", 6),
    summary(5, { status: "failed", error: fields.error ?? ERROR }),
  ]);
  return {
    ...base,
    summary: { ...base.summary!, status: "ready", queuePaused: fields.paused ?? true },
    queue: fields.queue ?? [],
    ...(fields.retrying !== false && { autoResume: { retry: retry() } }),
    ...(fields.surge !== false && { surge: { held: 6, needYou: 23, seq: 1 } }),
  };
}

const digest = { id: "surge-digest-1", prompt: DIGEST };
const mine = { id: "p-own", prompt: "Then rebase the picker stack onto feat-cmux-next." };

const armed = (arm: string) => ({ experiments: { "queue-status-look": arm } });

export default agentPaneEntry({
  id: "agent-pane.queue-status",
  title: "Status after a failed turn",
  area: "Agent pane",
  height: 460,
  covers: [
    "agent-session/acpmux/QueueStatusLine.tsx",
    "agent-session/acpmux/queueStatus.ts",
    "agent-session/acpmux/surgeDigest.ts",
    "agent-session/acpmux/AutoResumeNotice.tsx",
  ],
  variants: {
    inline: {
      note: "The pick: one line, the retry mark, 'Waiting for capacity' in ink, 'retrying in 9:42 · 1 of 4' muted, Details and Resume; the digest as 'Held messages 29 messages in 23 threads'.",
      snapshot: failed({ queue: [digest, mine] }),
      ...armed("inline"),
    },
    stacked: {
      note: "The state over its countdown, two lines.",
      snapshot: failed({ queue: [digest, mine] }),
      ...armed("stacked"),
    },
    dot: {
      note: "An attention dot in place of the mark.",
      snapshot: failed({ queue: [digest, mine] }),
      ...armed("dot"),
    },
    paused: {
      note: "Nothing retries it: 'Paused after an error', Details, Resume.",
      snapshot: failed({ queue: [mine], retrying: false, surge: false }),
    },
    "no-queue": {
      note: "Nothing queued: the notice slot's line says the same wait once it has lasted 10 s.",
      snapshot: failed({ paused: false, surge: false }),
    },
  },
});

// l10n-allow-file: test and gallery fixtures (sample prompts and replies), not shipped UI.
// A chat's turn lifecycle, one row per state, and what the composer and the turn's prompt may offer
// in each (Leo, 2026-11-22: "the cross vs edit vs anything, we need to be able to map out the
// lifecycle and what should reasonably be possible, when").
//
// The table is data: turnLifecycle.test.tsx draws the real Composer in each state and fails on any
// cell the pane disagrees with (a running turn with no Stop, Edit on a prompt the agent has already
// read); turnLifecycle.gallery.ts shows each state as a variant, its row as the note. A prompt's own
// stages (sending, queued, steer waiting, failed, read, answered) and each one's row actions are
// acpmux's table (acpmux-core `chat/prompt_lifecycle.rs`, conversation/promptLifecycle.test.tsx);
// this one is the turn's.
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";

/// The send slot's Stop with the prompt empty: Stop, Stop already sent (the turn has not ended on
/// it yet), or none.
export type StopCell = "stop" | "stopping" | "none";
/// What the send control does with a draft typed: send a new turn, steer it into the running turn,
/// queue it behind the turn, or no send control at all.
export type SendCell = "send" | "steer" | "queue" | "none";

export type TurnLifecycleRow = {
  /// The state's name, a gallery variant name.
  state: string;
  /// What the state is, in a line (the gallery's note opens with it).
  what: string;
  snapshot: AcpmuxSnapshot;
  /// The snapshot the pane showed just before, for a state reached only from another (a handover).
  from?: AcpmuxSnapshot;
  expect: {
    /// The send slot with the prompt empty.
    stop: StopCell;
    /// The send slot with a draft typed.
    send: SendCell;
    /// Whether Stop still shows beside the draft (never: one send control, Esc still stops).
    stopWithDraft: boolean;
    /// Whether Esc twice from the empty prompt stops the turn.
    escStops: boolean;
    /// Whether the turn's prompt (the chat's last) offers Edit and resend. Never while its turn
    /// runs: the agent has read it, so an edit could only fork through the turn before.
    edit: boolean;
    /// Whether a prompt waiting in the composer's queue offers its delete (✕ takes it back).
    queueDelete: boolean;
  };
};

export const LIFECYCLE_PROMPT = "Add retries to the fetch helper";
/// The turn's prompt, the row whose Edit each state checks.
export const TURN_PROMPT_ID = "lifecycle-turn-prompt";

const earlier = [
  user("Read the fetch helper", 6, { id: "lifecycle-first" }),
  assistant("It retries nothing and has no timeout.", 5.5, { id: "lifecycle-first-reply" }),
  summary(5.5, { id: "lifecycle-first-summary", seq: 4, status: "completed" }),
];
const asked = user(LIFECYCLE_PROMPT, 2, { id: TURN_PROMPT_ID });
const reading = assistant("Reading src/net/fetch.ts…", 1.5, { id: "lifecycle-reading" });
const ended = [
  assistant("Retries with backoff are in, with a test for the 429 path.", 0.5, { id: "lifecycle-reply" }),
  summary(0.5, { id: "lifecycle-summary", seq: 9, status: "completed" }),
];

const permission = {
  permissionId: "lifecycle-permission",
  title: "Run bun test src/net",
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "deny", name: "Reject", kind: "deny", allow: false },
  ],
};

/** The chat in one state: Claude Code, which steers and forks, unless `steering` is false. */
function state(
  rows: Parameters<typeof chat>[0],
  fields: Partial<AcpmuxSnapshot> & { steering?: boolean } = {},
): AcpmuxSnapshot {
  const { steering = true, ...rest } = fields;
  const snapshot = chat(rows, { title: "Turn lifecycle", isWorking: false, queue: [], ...rest });
  return { ...snapshot, summary: { ...snapshot.summary!, steering } };
}

const running = (fields: Partial<AcpmuxSnapshot> & { steering?: boolean } = {}) =>
  state([...earlier, asked, reading], { isWorking: true, ...fields });

const queued = [{ id: "lifecycle-queued", prompt: "Then add a test for the timeout path" }];

/// Every state of a turn, in the order a turn passes through them.
export const TURN_LIFECYCLE: TurnLifecycleRow[] = [
  {
    state: "idle",
    what: "No turn runs; the last one ended.",
    snapshot: state([...earlier, asked, reading, ...ended]),
    expect: { stop: "none", send: "send", stopWithDraft: false, escStops: false, edit: true, queueDelete: false },
  },
  {
    state: "starting",
    what: "A prompt sent while the chat's agent starts: held until it runs, and it reads as running.",
    snapshot: state([...earlier, { ...asked, queued: "held" }], {
      switching: { harness: "claude", name: "Claude Code", phase: "starting" },
    }),
    // No turn runs yet, so the draft is a send (acpmux steers it into the turn if one has started).
    expect: { stop: "stop", send: "send", stopWithDraft: false, escStops: true, edit: false, queueDelete: false },
  },
  {
    state: "running",
    what: "A turn runs and the agent has read its prompt.",
    snapshot: running(),
    expect: { stop: "stop", send: "steer", stopWithDraft: false, escStops: true, edit: false, queueDelete: false },
  },
  {
    state: "running-no-steer",
    what: "A turn runs for an agent that cannot take a prompt mid-turn.",
    snapshot: running({ steering: false }),
    expect: { stop: "stop", send: "queue", stopWithDraft: false, escStops: true, edit: false, queueDelete: false },
  },
  {
    state: "asking",
    what: "The running turn waits on a permission ask.",
    snapshot: running({ permission }),
    expect: { stop: "stop", send: "steer", stopWithDraft: false, escStops: true, edit: false, queueDelete: false },
  },
  {
    state: "queued",
    what: "A turn runs with a prompt waiting behind it.",
    snapshot: running({ queue: queued }),
    expect: { stop: "stop", send: "steer", stopWithDraft: false, escStops: true, edit: false, queueDelete: true },
  },
  {
    state: "stopping",
    what: "Stop was sent and the turn has not ended on it yet.",
    snapshot: running({ stopping: true }),
    expect: { stop: "stopping", send: "steer", stopWithDraft: false, escStops: false, edit: false, queueDelete: false },
  },
  {
    state: "offline",
    what: "A turn runs and the pane's link to acpmux is down: Stop is kept and goes once the link is back.",
    snapshot: running({ connection: "disconnected" }),
    expect: { stop: "stop", send: "steer", stopWithDraft: false, escStops: true, edit: false, queueDelete: false },
  },
  {
    state: "handover",
    what: "The turn ended with a queued prompt acpmux runs next: Stop stays until that turn starts.",
    from: running({ queue: queued }),
    snapshot: state([...earlier, asked, reading, ...ended], { queue: queued }),
    expect: { stop: "stop", send: "send", stopWithDraft: false, escStops: true, edit: true, queueDelete: true },
  },
];

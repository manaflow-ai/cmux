// l10n-allow-file: simulated chat fixtures for the chat simulator, not shipped UI.
// The chat simulator's scenario language (sim/README.md). A scenario is the records acpmux would
// write for a chat (`EventRecord`s, the shape `_acpmux/events` returns and session replay folds),
// on a virtual clock, plus the reader's own steps (scrolling) between them. Nothing here runs an
// agent: the pane folds these records with its real reducer (AcpmuxDirectClient.replay) and shapes
// them with its real turn view, so a scenario is a chat as the pane would draw it live.
//
// Leo, 2026-11-21: "we can do this without any real agent sessions, just simulated ones. ... we can
// just have simulations of things that go monstrously long".
import type { EventRecord } from "../direct";

/** What the reader does between two records: the simulator's only steps that are not acpmux's. */
export type ReaderAction = { scroll: "top" | "bottom" } | { scrollBy: number };

/** One step of a run: a record folded, or a reader action, at virtual time `at` (ms since the epoch). */
export type SimStep =
  | { type: "event"; seq: number; at: number; label: string }
  | { type: "reader"; at: number; label: string; reader: ReaderAction };

export type SimScenario = {
  name: string;
  /** One line: what the scenario reproduces or covers. */
  about: string;
  sessionId: string;
  /** The harness family a finished turn folds by (turnFoldStyle.ts): `claude` or `codex`. */
  family?: string;
  events: EventRecord[];
  steps: SimStep[];
};

export const SIM_SESSION = "sim-0000-0000-0000-000000000001";
export const SIM_START = Date.UTC(2026, 10, 21, 5, 0, 0);

const update = (sessionUpdate: string, fields: Record<string, unknown>) => ({
  jsonrpc: "2.0",
  method: "session/update",
  params: { sessionId: "agent-1", update: { sessionUpdate, ...fields } },
});
const text = (value: string) => ({ type: "text", text: value });

/** Splits `value` into about `chunks` pieces on word boundaries, as a stream delivers it. */
function chunked(value: string, chunks: number): string[] {
  if (chunks <= 1) return [value];
  const words = value.split(/(?<=\s)/);
  const per = Math.max(1, Math.ceil(words.length / chunks));
  const out: string[] = [];
  for (let index = 0; index < words.length; index += per) out.push(words.slice(index, index + per).join(""));
  return out;
}

export type ToolOptions = {
  kind?: "execute" | "read" | "edit" | "search" | "fetch" | "think" | "other";
  /** ms the call runs before its result. */
  ms?: number;
  output?: string;
  status?: "completed" | "failed";
  /** Claude Code's tool name (`_meta.claude.tool`): `Agent` makes a subagent call. */
  tool?: string;
  /** Leave the call running: no result record (end it later with `toolEnd`). */
  open?: boolean;
  path?: string;
};

export type IncomingOptions = {
  /** acpmux's provenance kind: `notice` (a one-line notice, as from a merge bot), `agent_message`, `session_message`. */
  kind?: "notice" | "agent_message" | "session_message";
  fromName?: string;
  /** A notice's title (kind `notice`). */
  title?: string;
};

/// Builds a scenario's records on a virtual clock. Every method returns the builder.
export class SimBuilder {
  readonly events: EventRecord[] = [];
  readonly steps: SimStep[] = [];
  private now = SIM_START;
  private seq = 0;
  private turns = 0;
  private calls = 0;
  private turnId: string | undefined;
  private promptId: string | undefined;

  constructor(
    readonly name: string,
    readonly about: string,
    readonly sessionId = SIM_SESSION,
    readonly family = "claude",
  ) {}

  /** Advances the virtual clock by `ms`. */
  wait(ms: number): this {
    this.now += ms;
    return this;
  }

  /** One raw record, after `after` ms (the escape hatch for any kind acpmux writes). */
  record(dir: string, kind: string, msg: Record<string, any>, after = 0, label = kind): this {
    this.now += after;
    this.seq += 1;
    this.events.push({ sessionId: this.sessionId, seq: this.seq, at: this.now, dir, kind, msg });
    this.steps.push({ type: "event", seq: this.seq, at: this.now, label });
    return this;
  }

  private newTurn() {
    this.turns += 1;
    this.turnId = `turn-${this.turns}`;
    this.promptId = `prompt-${this.turns}`;
  }

  private started(after: number): this {
    this.record("mux", "status", { status: "running" }, after, "status running");
    return this.record("mux", "turn_started", { turnId: this.turnId, promptId: this.promptId }, 0, "turn_started");
  }

  /** The person's prompt, and the turn it starts. */
  prompt(value: string, after = 1_000): this {
    this.newTurn();
    this.record(
      "mux",
      "user_message",
      {
        text: value,
        promptId: this.promptId,
        turnId: this.turnId,
        client: "pane",
        _meta: { origin: { actor: "person" } },
      },
      after,
      `prompt: ${value.slice(0, 40)}`,
    );
    return this.started(300);
  }

  /** Another agent's message (or a notice) that starts a turn (Leo's 2026-11-21 screenshot). */
  incoming(value: string, options: IncomingOptions = {}, after = 1_000): this {
    this.newTurn();
    const kind = options.kind ?? "notice";
    const fromName = options.fromName ?? "other-lane";
    const provenance: Record<string, unknown> = {
      kind,
      from: `sim-host/${fromName}`,
      fromName,
      fromSessionId: "sim-0000-0000-0000-0000000000aa",
      to: this.sessionId,
      ...(kind === "notice"
        ? {
            display: "line",
            notice: { sender: fromName, severity: "info", title: options.title ?? value.slice(0, 60) },
          }
        : {}),
    };
    this.record(
      "mux",
      "user_message",
      { text: value, promptId: this.promptId, turnId: this.turnId, client: "acpmux-cli#1", _meta: { provenance } },
      after,
      `incoming ${kind}: ${value.slice(0, 40)}`,
    );
    return this.started(300);
  }

  /** Another agent's message steered into the running turn (acpmux `steer`): no turn of its own. */
  steerIncoming(value: string, options: IncomingOptions = {}, after = 600): this {
    const fromName = options.fromName ?? "other-lane";
    const provenance = {
      kind: options.kind ?? "agent_message",
      from: `sim-host/${fromName}`,
      fromName,
      fromSessionId: "sim-0000-0000-0000-0000000000aa",
      to: this.sessionId,
    };
    this.steers += 1;
    return this.record(
      "mux",
      "user_message",
      {
        text: value,
        promptId: `steer-${this.turns}-${this.steers}`,
        turnId: this.turnId,
        steer: true,
        client: "acpmux-cli#1",
        _meta: { provenance },
      },
      after,
      `steer ${provenance.kind}: ${value.slice(0, 40)}`,
    );
  }
  private steers = 0;

  /** A background task's notice the harness hands the running turn (Claude Code's `<task-notification>`),
   *  under the background turn it starts (test/agent-pane-worked-group-pitch-browser.test.ts). */
  taskNotice(summary: string, id = "bgturn-notice", after = 600): this {
    this.record("mux", "background_turn", { id, state: "started", trigger: "task_notification" }, after);
    return this.record(
      "mux",
      "user_message",
      {
        text: `<task-notification>\n<task-id>${id}</task-id>\n<status>completed</status>\n<summary>${summary}</summary>\n</task-notification>`,
        client: "adopt",
      },
      50,
      `task notice: ${summary.slice(0, 40)}`,
    );
  }

  /** A thought, streamed in `chunks` deltas `chunkMs` apart. */
  think(value: string, { chunks = 3, chunkMs = 120, after = 400 } = {}): this {
    chunked(value, chunks).forEach((part, index) =>
      this.record(
        "in",
        "agent_thought_chunk",
        update("agent_thought_chunk", { content: text(part) }),
        index === 0 ? after : chunkMs,
        "thought delta",
      ),
    );
    return this;
  }

  /** The reply's text, streamed in `chunks` deltas `chunkMs` apart. */
  say(value: string, { chunks = 4, chunkMs = 80, after = 400 } = {}): this {
    chunked(value, chunks).forEach((part, index) =>
      this.record(
        "in",
        "agent_message_chunk",
        update("agent_message_chunk", { content: text(part) }),
        index === 0 ? after : chunkMs,
        "assistant delta",
      ),
    );
    return this;
  }

  /** A tool call: its start, and (unless `open`) its result `ms` later. Returns the builder; the call's id is `call-N`. */
  tool(title: string, options: ToolOptions = {}, after = 300): this {
    this.calls += 1;
    const id = `call-${this.calls}`;
    const kind = options.kind ?? "execute";
    this.record(
      "in",
      "tool_call",
      update("tool_call", {
        toolCallId: id,
        title,
        kind,
        status: "in_progress",
        ...(kind === "execute" ? { rawInput: { command: title, description: title } } : {}),
        ...(options.path ? { locations: [{ path: options.path }] } : {}),
        ...(options.tool ? { _meta: { claude: { tool: options.tool } } } : {}),
      }),
      after,
      `tool start: ${title.slice(0, 40)}`,
    );
    if (!options.open) this.toolEnd(id, options);
    return this;
  }

  /** The result of call `id` (`call-N`). */
  toolEnd(id: string, options: ToolOptions = {}): this {
    return this.record(
      "in",
      "tool_call_update",
      update("tool_call_update", {
        toolCallId: id,
        status: options.status ?? "completed",
        content: [{ type: "content", content: text(options.output ?? "ok") }],
      }),
      options.ms ?? 900,
      `tool ${options.status ?? "completed"}: ${id}`,
    );
  }

  /** The id the next `tool` call will take. */
  nextCallId(): string {
    return `call-${this.calls + 1}`;
  }

  /** A shell the agent left running in the background, and later its end (`ms` after). */
  background(command: string, { ms = 5_000, after = 300 } = {}): this {
    const id = this.nextCallId();
    this.tool(command, { ms: 200, output: "Command running in background with ID: bg-1" }, after);
    const task = { taskId: `bg-${id}`, toolCallId: id, command, description: command, origin: "bash" };
    this.record(
      "in",
      "background_task_update",
      update("background_task_update", { ...task, state: "running" }),
      100,
      "background running",
    );
    this.pendingBackground.push({ task, at: this.now + ms });
    return this;
  }
  private pendingBackground: { task: Record<string, unknown>; at: number }[] = [];

  /** Ends every background shell whose time has come (call after `turnEnd`, or anywhere). */
  backgroundEnds(): this {
    for (const { task, at } of this.pendingBackground.splice(0)) {
      if (at > this.now) this.now = at;
      this.record(
        "in",
        "background_task_update",
        update("background_task_update", { ...task, state: "completed" }),
        0,
        "background completed",
      );
    }
    return this;
  }

  /** A subagent call (Claude Code's Agent tool) that runs `ms` and reports. */
  subagent(description: string, { ms = 4_000, report = "Done: nothing found." } = {}): this {
    return this.tool(description, { kind: "think", tool: "Agent", ms, output: report });
  }

  /** The agent compacting its context: started, then completed `ms` later. */
  compaction({ ms = 2_000, after = 300 } = {}): this {
    this.record("in", "compaction", update("compaction", { state: "started" }), after, "compaction started");
    return this.record("in", "compaction", update("compaction", { state: "completed" }), ms, "compaction completed");
  }

  /** acpmux's turn end: `turn_end`, `turn_result`, and the session ready again. */
  turnEnd(status: "completed" | "failed" | "cancelled" = "completed", after = 500): this {
    this.record("mux", "turn_end", { turnId: this.turnId, stopReason: "end_turn" }, after, "turn_end");
    this.record(
      "mux",
      "turn_result",
      { status, turnId: this.turnId, promptId: this.promptId, stopReason: "end_turn", outputTokens: 1200 },
      20,
      "turn_result",
    );
    return this.record("mux", "status", { status: "ready" }, 10, "status ready");
  }

  /** The reader scrolls (`top`, `bottom`, or by px), `after` ms from now. */
  reader(action: ReaderAction, after = 200): this {
    this.now += after;
    const label = "scroll" in action ? `reader scroll ${action.scroll}` : `reader scrollBy ${action.scrollBy}`;
    this.steps.push({ type: "reader", at: this.now, label, reader: action });
    return this;
  }

  build(): SimScenario {
    return {
      name: this.name,
      about: this.about,
      sessionId: this.sessionId,
      family: this.family,
      events: this.events,
      steps: this.steps,
    };
  }
}

export const sim = (name: string, about: string, family?: string) => new SimBuilder(name, about, SIM_SESSION, family);

/// A scenario from recorded (or sanitized) records: each record is one step, on its own clock.
export function replayScenario(name: string, events: readonly EventRecord[], sessionId?: string): SimScenario {
  const sorted = [...events].sort((a, b) => a.seq - b.seq);
  const id = sessionId ?? sorted.find((event) => event.sessionId)?.sessionId ?? SIM_SESSION;
  const own = sorted.map((event) => ({ ...event, sessionId: id }));
  return {
    name,
    about: `replay of ${own.length} recorded records`,
    sessionId: id,
    events: own,
    steps: own.map((event) => ({ type: "event", seq: event.seq, at: event.at, label: event.kind })),
  };
}

// l10n-allow-file: simulated chat fixtures for the chat simulator, not shipped UI.
// The chat simulator's scenario language (sim/README.md). A scenario is the records acpmux would
// write for a chat (`EventRecord`s, the shape `_acpmux/events` returns and session replay folds),
// on a virtual clock, plus the reader's own steps (scrolling) between them. Nothing here runs an
// agent: the pane folds these records with its real reducer (AcpmuxDirectClient.replay) and shapes
// them with its real turn view, so a scenario is a chat as the pane would draw it live.
//
// Leo, 2026-11-21: "we can do this without any real agent sessions, just simulated ones. ... we can
// just have simulations of things that go monstrously long".
import type { EventRecord } from "../eventRecord";

/** What the reader does between two records: the simulator's only steps that are not acpmux's. */
export type ReaderAction = { scroll: "top" | "bottom" } | { scrollBy: number } | { open: string };

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
  /** The call's input as the harness sends it (an MCP call's arguments, such as acpmux's `wrap_up`). */
  rawInput?: Record<string, unknown>;
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
  prompt(value: string, after = 1_000, extra: Record<string, unknown> = {}): this {
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
        ...extra,
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

  /** Another agent's message steered into the running turn (acpmux's `steer: true` `agent_message`): it opens no turn. */
  message(value: string, { fromName = "other-lane", after = 400 } = {}): this {
    const fromSessionId = "sim-0000-0000-0000-0000000000bb";
    return this.record(
      "mux",
      "user_message",
      {
        text: value,
        steer: true,
        turnId: this.turnId,
        promptId: `${this.promptId}-steer-${this.seq + 1}`,
        client: "acpmux-peer#sim",
        _meta: {
          provenance: { kind: "agent_message", from: "fromAgent", fromName, fromSessionId, to: this.sessionId },
          _acpmuxMessage: {
            message: {
              at: this.now + after,
              messageId: `sim-msg-${this.seq + 1}`,
              receiverId: this.sessionId,
              recordSenderCopy: false,
              sender: { label: fromName, name: fromName, sessionId: fromSessionId },
              text: value,
            },
          },
        },
      },
      after,
      `message from ${fromName}: ${value.slice(0, 40)}`,
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
        ...(options.rawInput
          ? { rawInput: options.rawInput }
          : kind === "execute"
            ? { rawInput: { command: title, description: title } }
            : {}),
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

  /** The person's steer mid-turn (`steer: true` on the running turn), and acpmux saying the agent read it `readMs` later
   *  (`false`: the agent has not read it yet). */
  steer(
    value: string,
    {
      readMs = 600,
      after = 300,
      extra = {},
    }: { readMs?: number | false; after?: number; extra?: Record<string, unknown> } = {},
  ): this {
    const promptId = `steer-${this.seq + 1}`;
    this.record(
      "mux",
      "user_message",
      {
        text: value,
        promptId,
        turnId: this.turnId,
        steer: true,
        client: "pane",
        _meta: { origin: { actor: "person" } },
        ...extra,
      },
      after,
      `steer: ${value.slice(0, 40)}`,
    );
    if (readMs === false) return this;
    return this.record("mux", "steer_read", { promptId, turnId: this.turnId }, readMs, "steer_read");
  }

  /** A subagent call (Claude Code's Agent tool) that runs `ms` and reports. `tracked`: acpmux also
   * reports the subagent's start and end (subagents.rs), so the chat draws it as a subagent. */
  subagent(description: string, { ms = 4_000, report = "Done: nothing found.", tracked = false } = {}): this {
    if (!tracked) return this.tool(description, { kind: "think", tool: "Agent", ms, output: report });
    this.tool(description, { kind: "think", tool: "Agent", open: true });
    const id = `call-${this.calls}`;
    const agent = `agent-${this.calls}`;
    const change = (fields: Record<string, unknown>) => {
      const msg = update(fields.state === "running" ? "subagent_spawned" : "subagent_state_update", {});
      return { ...msg, params: { ...msg.params, _meta: { acpmux: { subagents: [{ id: agent, ...fields }] } } } };
    };
    const name = description.slice(0, 40);
    this.record(
      "in",
      "subagent_spawned",
      change({ parent: null, name, task: description, state: "running", startedAt: this.now }),
      50,
      "subagent spawned",
    );
    this.record(
      "in",
      "subagent_state_update",
      change({ state: "completed", lastMessage: report, endedAt: this.now + ms }),
      ms,
      "subagent completed",
    );
    return this.toolEnd(id, { output: report, ms: 50 });
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

  /** The agent's checklist (ACP `plan`): each entry `[content, status]`; none clears it. */
  plan(entries: [string, "pending" | "in_progress" | "completed"][], after = 300): this {
    return this.record(
      "in",
      "plan",
      update("plan", { entries: entries.map(([content, status]) => ({ content, status, priority: "medium" })) }),
      after,
      `plan: ${entries.filter(([, status]) => status === "completed").length}/${entries.length}`,
    );
  }

  /** acpmux asks the person to allow call `id`, and `ms` later records the answer (`allow`, or `null`: still waiting). */
  permission(id: string, { ms = 4_000, allow = true as boolean | null, after = 100 } = {}): this {
    const permissionId = `perm-${id}`;
    const options = [
      { optionId: "allow", name: "Allow", kind: "allow_once" },
      { optionId: "reject", name: "Deny", kind: "reject_once" },
    ];
    this.record(
      "mux",
      "permission_request",
      { permissionId, request: { sessionId: "agent-1", toolCall: { toolCallId: id, title: id }, options } },
      after,
      `permission asked: ${id}`,
    );
    if (allow === null) return this;
    return this.record(
      "mux",
      "permission_decision",
      { permissionId, outcome: { outcome: "selected", optionId: allow ? "allow" : "reject" } },
      ms,
      `permission ${allow ? "allowed" : "denied"}: ${id}`,
    );
  }

  /** The person's Stop: acpmux's `stopping`, each running call of `calls` ends interrupted (as the harness
   *  ends them), then the turn ends cancelled `ms` later. */
  stop({ calls = [] as string[], ms = 600, after = 300 } = {}): this {
    this.record("mux", "stopping", { turnId: this.turnId }, after, "stopping");
    for (const id of calls)
      this.toolEnd(id, { ms: 200, status: "failed", output: "[Request interrupted by user for tool use]" });
    return this.turnEnd("cancelled", ms);
  }

  /** The turn fails: acpmux's `turn_error`, then a failed `turn_result` carrying the error. */
  fail(error: string, after = 500): this {
    this.record("mux", "turn_error", { turnId: this.turnId, error }, after, "turn_error");
    this.record(
      "mux",
      "turn_result",
      { status: "failed", turnId: this.turnId, promptId: this.promptId, error, errorText: error },
      20,
      "turn_result",
    );
    return this.record("mux", "status", { status: "ready" }, 10, "status ready");
  }

  /** The model cannot be reached: acpmux retries the turn's request, and `ms` later hears it again. */
  retry({ ms = 8_000, attempts = 2, after = 400 } = {}): this {
    for (let attempt = 1; attempt <= attempts; attempt += 1)
      this.record(
        "mux",
        "turn_retrying",
        { turnId: this.turnId, attempt, maxAttempts: 10, delayMs: ms / attempts, error: "overloaded" },
        attempt === 1 ? after : ms / attempts,
        `turn_retrying ${attempt}`,
      );
    return this.record("mux", "turn_heard", { turnId: this.turnId }, ms / attempts, "turn_heard");
  }

  /** The reader scrolls (`top`, `bottom`, or by px) or opens a fold (its row id, `worked-user-12`), `after` ms from now. */
  reader(action: ReaderAction, after = 200): this {
    this.now += after;
    const label =
      "scroll" in action
        ? `reader scroll ${action.scroll}`
        : "open" in action
          ? `reader open ${action.open}`
          : `reader scrollBy ${action.scrollBy}`;
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

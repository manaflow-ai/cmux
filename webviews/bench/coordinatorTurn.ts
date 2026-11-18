// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// The records of a coordinator chat's turn that never ends, step by step, for chat-100k-flat's CASES=coordinator:
// what a lead session's open turn takes for hours. Each step is a reply (short chunks, and every fifth one a long
// markdown answer with a code block and a table, streamed in small chunks), a shell call whose output acpmux sends
// whole with each update (every third one 12 KB of log), and now and then: a subagent run (an Agent call, the
// subagent's spawn, its own tool calls and replies tagged with it, its progress, a nested subagent of its own, its
// end and the Agent call's result), a send to another agent (an acpmux MCP send), another agent's message steered
// into the turn, a permission ask and its answer, a plan (TodoWrite) and a usage update, and a `wait` call that stays
// in progress across fifty steps.
// Shapes: subagents/subagentFold.ts (`_meta.acpmux.subagents`, `_meta.acpmux.subagent`), mockFixture.ts (permission
// and subagent records), direct.ts `queuedMessage` (`fromAgent`).

/// One record without its seq, session and time: [dir, kind, msg].
export type CoordinatorRecord = [dir: string, kind: string, msg: Record<string, unknown>];

const update = (u: Record<string, unknown>, meta?: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: u, ...(meta ? { _meta: { acpmux: meta } } : {}) },
});
const said = (u: Record<string, unknown>, meta?: Record<string, unknown>): CoordinatorRecord => [
  "in",
  String(u.sessionUpdate),
  update(u, meta),
];
const text = (value: string) => ({ type: "text", text: value });
const output = (value: string) => [{ type: "content", content: text(value) }];

/// A log of about `bytes` bytes, as a CI wait or a build prints it.
function log(step: number, bytes: number): string {
  const lines: string[] = [];
  let size = 0;
  for (let n = 0; size < bytes; n++) {
    const line = `2026-11-18T09:${String(n % 60).padStart(2, "0")}:00Z [step ${step}] job ${n}: test suite ${n % 17} passed (${(n * 37) % 991} ms)`;
    lines.push(line);
    size += line.length + 1;
  }
  return lines.join("\n");
}

/// A long markdown answer: a heading, a list, a code block and a table.
function markdown(step: number): string {
  const rows = Array.from(
    { length: 12 },
    (_, n) => `| lane-${step}-${n} | #${45000 + n} | ${n % 3 ? "green" : "running"} | ${(n * 7) % 60} min |`,
  );
  return [
    `## Status at step ${step}`,
    "",
    "The lanes are moving. **Two** need a review and one waits on CI:",
    "",
    "- `lane/chat-history-memory`: merged, the heap is flat.",
    "- `lane/coordinator-loop`: draft, the bench runs.",
    "- `lane/live-line`: waiting on `glaeda-gh wait` for the run.",
    "",
    "```ts",
    "export function settle(rows: Row[], from: number): Row[] {",
    "  const out: Row[] = [];",
    "  for (let index = from; index < rows.length; index++) {",
    "    const row = rows[index]!;",
    "    if (row.kind === 'activity' && row.items?.length) out.push({ ...row, settled: true });",
    "    else out.push(row);",
    "  }",
    "  return out;",
    "}",
    "```",
    "",
    "| Lane | PR | Checks | Age |",
    "| --- | --- | --- | --- |",
    ...rows,
    "",
    `Next: I'll check back on the waits and send the reviewers their diffs (step ${step}).`,
  ].join("\n");
}

/// Splits `value` into chunks of about `size` characters, as a model streams it.
const chunks = (value: string, size: number) =>
  Array.from({ length: Math.ceil(value.length / size) }, (_, n) => value.slice(n * size, (n + 1) * size));

/// A live subagent: its id, its Agent call, its name and when it ends.
type Live = { id: string; call: string; name: string; parent: string | null; ends: number; tools: number };

/// The records of a coordinator's open turn, from `step` 1 on; `start` gives its prompt and turn start (once).
export class CoordinatorTurn {
  private readonly live: Live[] = [];

  /// The turn's opening records: its prompt and its start.
  start(): CoordinatorRecord[] {
    return [
      ["mux", "user_message", { text: "Coordinate the lanes until every ask is landed" }],
      ["mux", "turn_started", {}],
    ];
  }

  /// The records of step `step` (1, 2, ...).
  step(step: number): CoordinatorRecord[] {
    const out: CoordinatorRecord[] = [];
    // Another agent's message, steered into the running turn (acpmux send --from).
    if (step % 9 === 0)
      out.push([
        "mux",
        "user_message",
        {
          text: `from lane-${step % 13} (an agent, not the person)\nLanded the fix for step ${step}; CI is green, the PR is ready for a review.`,
          steer: true,
          fromAgent: `lane-${step % 13}`,
        },
      ]);
    // The reply: every fifth a long markdown answer in 60-character chunks, else a sentence in a few.
    const reply =
      step % 5 === 0 ? markdown(step) : `Step ${step}: checked the lanes; two are green and one waits on CI. `;
    for (const chunk of chunks(reply, step % 5 === 0 ? 60 : 24))
      out.push(said({ sessionUpdate: "agent_message_chunk", messageId: `m-${step}`, content: text(chunk) }));
    // A plan, as TodoWrite keeps it.
    if (step % 20 === 0)
      out.push(
        said({
          sessionUpdate: "plan",
          entries: Array.from({ length: 6 }, (_, n) => ({
            content: `Land ask ${step + n}`,
            status: n < 2 ? "completed" : n === 2 ? "in_progress" : "pending",
            priority: "medium",
          })),
        }),
      );
    // A shell call with a large output, sent whole with each update.
    const call = `c-${step}`;
    const command = `glaeda-gh status pr ${45000 + step}`;
    const bytes = step % 3 === 0 ? 12_000 : 600;
    out.push(
      said({
        sessionUpdate: "tool_call",
        toolCallId: call,
        title: command,
        kind: "execute",
        status: "in_progress",
        rawInput: { command },
      }),
      said({
        sessionUpdate: "tool_call_update",
        toolCallId: call,
        status: "in_progress",
        content: output(log(step, bytes / 2)),
      }),
      said({
        sessionUpdate: "tool_call_update",
        toolCallId: call,
        status: "completed",
        content: output(log(step, bytes)),
      }),
    );
    // A wait that runs across fifty steps.
    if (step % 50 === 1)
      out.push(
        said({
          sessionUpdate: "tool_call",
          toolCallId: `wait-${step}`,
          title: `glaeda-gh wait pr ${45000 + step} --timeout 1800`,
          kind: "execute",
          status: "in_progress",
          rawInput: { command: `glaeda-gh wait pr ${45000 + step} --timeout 1800` },
        }),
      );
    if (step % 50 === 41)
      out.push(
        said({
          sessionUpdate: "tool_call_update",
          toolCallId: `wait-${step - 40}`,
          status: "completed",
          content: output(log(step, 2_000)),
        }),
      );
    // A send to another agent (acpmux's MCP send).
    if (step % 7 === 0) {
      const send = `send-${step}`;
      out.push(
        said({
          sessionUpdate: "tool_call",
          toolCallId: send,
          title: "mcp__acpmux__send",
          kind: "other",
          status: "in_progress",
          rawInput: { session: `lane-${step % 11}`, text: `Review PR #${45000 + step} and post the receipt.` },
        }),
        said({
          sessionUpdate: "tool_call_update",
          toolCallId: send,
          status: "completed",
          content: output('{"delivered":true}'),
        }),
      );
    }
    // A permission ask and its answer.
    if (step % 25 === 0) {
      const ask = `ask-${step}`;
      const title = `git push -u origin HEAD:lane/step-${step}`;
      out.push(
        said({ sessionUpdate: "tool_call", toolCallId: ask, title, kind: "execute", status: "pending" }),
        [
          "mux",
          "permission_request",
          {
            permissionId: `perm-${step}`,
            request: {
              toolCall: { toolCallId: ask, title, kind: "execute" },
              options: [
                { optionId: "allow_once", name: "Allow", kind: "allow_once" },
                { optionId: "allow_always", name: "Always allow", kind: "allow_always" },
                { optionId: "reject_once", name: "Deny", kind: "reject_once" },
              ],
            },
          },
        ],
        ["mux", "permission_decision", { permissionId: `perm-${step}`, optionId: "allow_once" }],
        said({ sessionUpdate: "tool_call_update", toolCallId: ask, status: "completed", content: output("pushed") }),
      );
    }
    // A subagent run every sixth step, living fifteen steps (two or three at once); every fifth run spawns one of its
    // own.
    if (step % 6 === 0) {
      const agentCall = `agent-${step}`;
      const id = `sub-${step}`;
      const name = `reviewer-${step}`;
      out.push(
        said({
          sessionUpdate: "tool_call",
          toolCallId: agentCall,
          title: "Agent",
          kind: "think",
          status: "in_progress",
          rawInput: {
            description: `Review step ${step}`,
            prompt: `Review the diff of step ${step}.`,
            subagent_type: "general-purpose",
          },
        }),
        said(
          { sessionUpdate: "subagent_spawned", subagentSessionId: id },
          {
            subagents: [
              { id, parent: null, name, task: `Review step ${step}`, state: "running", toolCallId: agentCall },
            ],
          },
        ),
      );
      this.live.push({ id, call: agentCall, name, parent: null, ends: step + 15, tools: 0 });
      if (step % 30 === 0) {
        const nested = `${id}-nested`;
        out.push(
          said(
            { sessionUpdate: "subagent_spawned", subagentSessionId: nested },
            {
              subagent: id,
              subagents: [{ id: nested, parent: id, name: `${name}-helper`, task: "Read the tests", state: "running" }],
            },
          ),
        );
        this.live.push({ id: nested, call: "", name: `${name}-helper`, parent: id, ends: step + 8, tools: 0 });
      }
    }
    for (const agent of this.live.splice(0)) {
      if (step < agent.ends) {
        this.live.push(agent);
        agent.tools++;
        const child = `${agent.id}-t${agent.tools}`;
        const tag = { subagent: agent.id };
        out.push(
          said(
            {
              sessionUpdate: "agent_message_chunk",
              messageId: `${agent.id}-m${agent.tools}`,
              content: text(`Reading part ${agent.tools}. `),
            },
            tag,
          ),
          said(
            {
              sessionUpdate: "tool_call",
              toolCallId: child,
              title: `Read src/part-${agent.tools}.ts`,
              kind: "read",
              status: "in_progress",
            },
            tag,
          ),
          said(
            {
              sessionUpdate: "tool_call_update",
              toolCallId: child,
              status: "completed",
              content: output(log(step, 1_500)),
            },
            tag,
          ),
          said(
            { sessionUpdate: "subagent_progress", subagentSessionId: agent.id },
            {
              subagents: [
                {
                  id: agent.id,
                  parent: agent.parent,
                  name: agent.name,
                  state: "running",
                  action: `Read src/part-${agent.tools}.ts`,
                  tokens: agent.tools * 1_800,
                  toolUses: agent.tools,
                },
              ],
            },
          ),
        );
        continue;
      }
      out.push(
        said(
          { sessionUpdate: "subagent_state_update", subagentSessionId: agent.id, state: "completed" },
          {
            subagents: [
              {
                id: agent.id,
                parent: agent.parent,
                name: agent.name,
                state: "completed",
                lastMessage: `Reviewed: no blocking findings in ${agent.tools} files.`,
              },
            ],
          },
        ),
      );
      if (agent.call)
        out.push(
          said({
            sessionUpdate: "tool_call_update",
            toolCallId: agent.call,
            status: "completed",
            content: output(`Reviewed: no blocking findings in ${agent.tools} files.\nagentId: ${agent.id}`),
          }),
        );
    }
    if (step % 10 === 0)
      out.push(said({ sessionUpdate: "usage_update", used: 40_000 + (step % 150_000), size: 200_000 }));
    return out;
  }
}

// l10n-allow-file: test fixture prompts, replies and tool titles, not shipped UI.
// Running turns of a long Claude Code coordinator chat (many tool calls, MCP calls, discovery calls,
// background tasks, other agents' messages and the person's own steers), as raw rows step by step,
// for the Thinking line gap checks (thinking-gap-browser.test.ts, thinking-gap.test.ts).
import type { AcpmuxActivity, AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { received } from "../../src/agent-session/acpmux/incomingFixture";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
/// `working: false` on the step that ends the turn (an `end` event): the harness draws it at rest,
/// so the turn-end fold plays.
export type Step = { name: string; rows: AcpmuxRow[]; width?: number; scroll?: "up" | "down"; working?: false };

/// One event of a running turn: what it adds to the turn's rows.
export type GapEvent =
  | { kind: "tool"; title?: string; tool?: string; status?: "pending" | "completed" | "failed"; fresh?: boolean }
  | { kind: "finish" }
  | { kind: "toolSearch"; fresh?: boolean }
  | { kind: "wrapUp"; fresh?: boolean }
  | { kind: "mcp"; fresh?: boolean }
  | { kind: "background"; fresh?: boolean }
  | { kind: "thought"; ended?: boolean }
  | { kind: "reply"; text?: string; streaming?: boolean }
  | { kind: "steer" }
  | { kind: "message" }
  | { kind: "plan" }
  /// A subagent starts (its group row joins the turn), or the oldest running one ends: its group
  /// reads it ended and its "Subagent finished" line lands where it ended (a harness event).
  | { kind: "subagent" }
  | { kind: "subagentEnd"; state?: "completed" | "disconnected" | "failed" }
  /// The turn ends: its turnSummary lands and the turn is drawn at rest.
  | { kind: "end" }
  | { kind: "width"; px: number }
  | { kind: "scroll"; to: "up" | "down" };

const LONG = Array.from(
  { length: 30 },
  (_, index) =>
    `Lane ${index + 1} reported in: its pull request is green and waits for the merge queue, so the coordinator keeps it on the board and moves on.`,
).join("\n\n");

/// Plays `events` into a running turn after a long finished history, one step per event.
export function playTurn(events: readonly GapEvent[], start = Date.now() - 60_000): Step[] {
  const base: AcpmuxRow[] = [
    { id: "h-prompt", version: 1, at: start - 50_000, kind: "user", text: "Coordinate the lanes." } as AcpmuxRow,
    { id: "h-reply", version: 1, at: start - 49_000, kind: "assistant", text: LONG } as AcpmuxRow,
    {
      id: "h-summary",
      version: 1,
      at: start - 48_000,
      kind: "turnSummary",
      durationMs: 2_000,
      toolCount: 0,
    } as AcpmuxRow,
    {
      id: "prompt",
      version: 1,
      at: start,
      kind: "user",
      text: "Check every lane and land what is green.",
    } as AcpmuxRow,
  ];
  const turn: AcpmuxRow[] = [];
  let version = 1;
  let at = start + 1_000;
  let calls = 0;
  let rowsMade = 0;
  let width: number | undefined;
  let ended = false;
  let agents = 0;
  const steps: Step[] = [];
  /// The open activity row the next call joins (a run), if the last row is one.
  const openRun = () => {
    const last = turn.at(-1);
    return last?.kind === "activity" ? last : undefined;
  };
  const putItem = (item: AcpmuxActivity, fresh = false) => {
    const run = fresh ? undefined : openRun();
    if (run) {
      const next = { ...run, version: ++version, items: [...(run.items ?? []), item] } as AcpmuxRow;
      turn[turn.length - 1] = next;
    } else turn.push({ id: `run-${++rowsMade}`, version: ++version, at, kind: "activity", items: [item] } as AcpmuxRow);
  };
  const tool = (fields: Partial<Tool> & { title: string }): AcpmuxActivity => ({
    kind: "tool",
    text: fields.title,
    tool: { id: `call-${++calls}`, status: "completed", startedAt: at, endedAt: at + 300, ...fields } as Tool,
  });
  for (const [index, event] of events.entries()) {
    at += 700;
    let scroll: Step["scroll"];
    switch (event.kind) {
      case "tool":
        putItem(
          tool({
            title: event.title ?? `rg retry lane-${index}`,
            kind: event.tool ?? "execute",
            status: event.status ?? "pending",
            command: event.tool === undefined || event.tool === "execute" ? `rg retry lane-${index}` : undefined,
            ...(event.status !== "completed" && { endedAt: undefined }),
          }),
          event.fresh,
        );
        break;
      case "finish": {
        // The last pending call finishes.
        for (let at = turn.length - 1; at >= 0; at -= 1) {
          const row = turn[at]!;
          const items = row.items ?? [];
          let open = items.length - 1;
          while (open >= 0 && items[open]!.tool?.status !== "pending") open -= 1;
          if (row.kind !== "activity" || open < 0) continue;
          const done = items.map((item, i) =>
            i === open ? { ...item, tool: { ...item.tool!, status: "completed", endedAt: Date.now() } } : item,
          );
          turn[at] = { ...row, version: ++version, items: done } as AcpmuxRow;
          break;
        }
        break;
      }
      case "toolSearch":
        putItem(
          tool({
            title: "ToolSearch",
            kind: "other",
            inputSummary: '{"query":"select:mcp__github__ci"}',
            output: "Loaded 1 tool",
            provenance: { claudeTool: "ToolSearch" },
          } as Partial<Tool> & { title: string }),
          event.fresh,
        );
        break;
      case "wrapUp":
        putItem(
          tool({
            title: "mcp__acpmux__wrap_up",
            kind: "other",
            inputSummary: JSON.stringify({ recap: "Landed two lanes; one waits on CI." }),
            output: "ok",
          }),
          event.fresh,
        );
        break;
      case "mcp":
        putItem(
          tool({
            title: "mcp__github__ci_status",
            kind: "other",
            inputSummary: JSON.stringify({ repo: "o/r", pr: 100 + index }),
            output: JSON.stringify({ state: "success" }),
          }),
          event.fresh,
        );
        break;
      case "background":
        putItem(
          tool({
            title: "Watch CI",
            kind: "execute",
            command: "glaeda-gh wait pr o/r#1",
            background: { state: "running" },
          } as Partial<Tool> & { title: string }),
          event.fresh,
        );
        break;
      case "thought": {
        const last = openRun();
        const lastItem = last?.items?.at(-1);
        if (last && lastItem?.kind === "thought" && lastItem.endedAt === undefined) {
          const items = [...last.items!];
          items[items.length - 1] = {
            ...lastItem,
            text: `${lastItem.text} Then the next lane.`,
            ...(event.ended && { endedAt: Date.now() }),
          };
          turn[turn.length - 1] = { ...last, version: ++version, items } as AcpmuxRow;
        } else
          putItem({
            kind: "thought",
            text: "Checking which lanes are green.",
            startedAt: Date.now(),
            ...(event.ended && { endedAt: Date.now() }),
          });
        break;
      }
      case "reply": {
        const last = turn.at(-1);
        if (last?.kind === "assistant" && last.streaming)
          turn[turn.length - 1] = {
            ...last,
            version: ++version,
            text: `${last.text} ${event.text ?? "And the next one is green too."}`,
            streaming: event.streaming ?? false,
          } as AcpmuxRow;
        else
          turn.push({
            id: `reply-${++rowsMade}`,
            version: ++version,
            at,
            kind: "assistant",
            text: event.text ?? "Lane 4 is green; landing it now.",
            streaming: event.streaming ?? true,
          } as AcpmuxRow);
        break;
      }
      case "steer":
        turn.push({
          id: `steer-${++rowsMade}`,
          version: ++version,
          at,
          kind: "user",
          text: "also check the docs lane",
          steer: "landed",
        } as AcpmuxRow);
        break;
      case "message":
        turn.push({
          ...received(`msg-${++rowsMade}`, at, {
            id: `msg_${rowsMade.toString(16).padStart(32, "0")}`,
            thread: `msg_${rowsMade.toString(16).padStart(32, "0")}`,
            sender: "cli",
            name: `lane-${rowsMade}`,
            body: "Lane done: PR is green.",
          }),
          version: ++version,
        });
        break;
      case "plan":
        turn.push({
          id: `plan-${++rowsMade}`,
          version: ++version,
          at,
          kind: "plan",
          plan: [
            { content: "Check lanes", status: "completed" },
            { content: "Land green PRs", status: "in_progress" },
            { content: "Report", status: "pending" },
          ],
        } as AcpmuxRow);
        break;
      case "subagent": {
        const id = `agent-${++agents}`;
        turn.push({
          id: `group-${id}`,
          version: ++version,
          at,
          kind: "subagents",
          subagents: [
            {
              id,
              parent: null,
              name: `helper-${agents}`,
              task: `Check lane ${agents}`,
              state: "running",
              startedAt: at,
            },
          ],
        } as AcpmuxRow);
        break;
      }
      case "subagentEnd": {
        const index = turn.findIndex((row) => row.kind === "subagents" && row.subagents?.[0]?.state === "running");
        if (index < 0) break;
        const group = turn[index]!;
        const agent = { ...group.subagents![0]!, state: event.state ?? "completed", endedAt: at };
        turn[index] = { ...group, version: ++version, subagents: [agent] } as AcpmuxRow;
        turn.push({
          id: `subagentDone:${agent.id}`,
          version: ++version,
          at,
          kind: "subagentDone",
          subagents: [agent],
        } as AcpmuxRow);
        break;
      }
      case "end":
        turn.push({
          id: `summary-${++rowsMade}`,
          version: ++version,
          at,
          kind: "turnSummary",
          status: "completed",
          durationMs: at - start,
          toolCount: calls,
        } as AcpmuxRow);
        ended = true;
        break;
      case "width":
        width = event.px;
        break;
      case "scroll":
        scroll = event.to;
        break;
    }
    steps.push({
      name: `${index}:${event.kind}`,
      rows: [...base, ...turn],
      ...(width !== undefined && { width }),
      ...(scroll && { scroll }),
      ...(ended && { working: false as const }),
    });
  }
  return steps;
}

/// A seeded pseudo-random coordinator turn of `count` events (mulberry32), weighted as a long Claude
/// Code coordinator's: mostly calls, then thoughts, replies, MCP and discovery calls, messages, steers.
export function randomTurn(seed: number, count: number): GapEvent[] {
  let state = seed >>> 0;
  const random = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const kinds: [GapEvent, number][] = [
    [{ kind: "tool" }, 8],
    [{ kind: "finish" }, 7],
    [{ kind: "tool", tool: "read", title: "Read lanes.md", status: "completed" }, 4],
    [{ kind: "thought" }, 3],
    [{ kind: "thought", ended: true }, 2],
    [{ kind: "mcp" }, 3],
    [{ kind: "mcp", fresh: true }, 1],
    [{ kind: "toolSearch" }, 2],
    [{ kind: "toolSearch", fresh: true }, 2],
    [{ kind: "wrapUp" }, 1],
    [{ kind: "wrapUp", fresh: true }, 1],
    [{ kind: "background" }, 1],
    [{ kind: "reply" }, 2],
    [{ kind: "reply", streaming: false }, 1],
    [{ kind: "message" }, 2],
    [{ kind: "steer" }, 1],
  ];
  const total = kinds.reduce((sum, [, weight]) => sum + weight, 0);
  const out: GapEvent[] = [];
  for (let index = 0; index < count; index += 1) {
    let pick = random() * total;
    for (const [event, weight] of kinds) {
      pick -= weight;
      if (pick <= 0) {
        out.push(event);
        break;
      }
    }
  }
  return out;
}

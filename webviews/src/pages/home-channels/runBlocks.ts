import type { AcpmuxActivity, AcpmuxRow } from "../../agent-session/acpmux/model";
import type { HomeRun, HomeRunStep } from "./types";
import { stepActivity } from "./runMessages";

/** Consecutive tool steps as one agent-pane activity row; text and thought steps between them. */
export type RunBlock =
  | { kind: "tools"; key: string; row: AcpmuxRow }
  | { kind: "talk"; key: string; step: HomeRunStep }
  | { kind: "thought"; key: string; step: HomeRunStep }
  | { kind: "note"; key: string; step: HomeRunStep };

/** The small presentation model used by Home's grouped tool summary.  Keep this separate from
 * the ACP row model: Home should be able to describe a call without leaking its wire arguments. */
export type HomeToolKind = "command" | "read" | "edit" | "search" | "capture" | "tool";

export interface HomeToolEntry {
  step: HomeRunStep;
  kind: HomeToolKind;
  title: string;
}

export interface HomeToolGroup {
  entries: HomeToolEntry[];
  summary: string;
}

const LOADED_TOOL_NAMES = /(?:tool[_-]?search|load(?:ed)?[_-]?tools?|list[_-]?tools?)/i;
const WAITING_TEXT = /^(?:waiting|queued|loading)(?:[.\s…]*)$/i;

/** True when a step carries no user-helpful result and is only protocol/UI noise. */
export function isHomeToolNoise(step: HomeRunStep): boolean {
  if (step.kind !== "tool" || !step.tool) return true;
  const tool = step.tool;
  if (LOADED_TOOL_NAMES.test(tool.name) && !tool.files.length && !tool.output?.trim()) return true;
  const text = `${tool.title ?? ""} ${tool.output ?? ""}`.trim();
  return !tool.input && !tool.files.length && (!text || WAITING_TEXT.test(text));
}

function inputString(step: HomeRunStep, key: string): string | undefined {
  const input = step.tool?.input;
  if (!input || typeof input !== "object") return undefined;
  const value = (input as Record<string, unknown>)[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

/** A one-line title suitable for the collapsed step list; raw JSON keys never reach this output. */
export function homeToolTitle(step: HomeRunStep): string {
  const tool = step.tool;
  if (!tool) return "Tool call";
  const explicit = tool.title?.trim();
  const command = inputString(step, "command") ?? inputString(step, "cmd");
  if (command) return command.split("\n", 1)[0]!.trim().slice(0, 120);
  if (explicit && !/^\{.*\}$/.test(explicit)) return explicit;
  const subject = inputString(step, "file_path") ?? inputString(step, "path") ?? inputString(step, "query");
  if (subject) return `${tool.name} ${subject}`.trim().slice(0, 120);
  return tool.name.replace(/[_-]+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function homeToolKind(step: HomeRunStep): HomeToolKind {
  const name = step.tool?.name ?? "";
  if (/^todowrite$/i.test(name)) return "tool";
  const value = `${step.tool?.kind ?? ""} ${name}`;
  const tokens = value
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
  const has = (...words: string[]) => words.some((word) => tokens.includes(word));
  if (has("shell", "bash", "zsh", "fish", "sh", "command", "terminal", "exec", "execute", "run")) return "command";
  if (
    has("edit", "write", "patch", "delete", "move", "rename") ||
    step.tool?.files.some((file) => file.newText !== undefined)
  )
    return "edit";
  if (has("search", "grep", "glob", "find", "query")) return "search";
  if (has("read", "cat", "open", "list", "stat")) return "read";
  if (step.attachments.length > 0 || has("capture", "screenshot", "image", "record")) return "capture";
  return "tool";
}

/** Build the concise Home summary while retaining source steps for drill-in details. */
export function homeToolGroup(steps: readonly HomeRunStep[]): HomeToolGroup {
  const entries = steps
    .filter((step) => !isHomeToolNoise(step))
    .map((step) => ({ step, kind: homeToolKind(step), title: homeToolTitle(step) }));
  const counts = new Map<HomeToolKind, number>();
  for (const entry of entries) counts.set(entry.kind, (counts.get(entry.kind) ?? 0) + 1);
  const parts: string[] = [];
  const labels: Record<HomeToolKind, string> = {
    command: "command",
    read: "read",
    edit: "edit",
    search: "search",
    capture: "capture",
    tool: "tool",
  };
  for (const kind of ["command", "read", "edit", "search", "capture", "tool"] as HomeToolKind[]) {
    const count = counts.get(kind);
    if (count) parts.push(`${count} ${labels[kind]}${count === 1 ? "" : "s"}`);
  }
  return { entries, summary: parts.length ? `Ran ${parts.join(", ")}` : "No visible tool calls" };
}

export function runBlocks(run: HomeRun, steps: readonly HomeRunStep[]): RunBlock[] {
  const blocks: RunBlock[] = [];
  let items: AcpmuxActivity[] = [];
  let first: HomeRunStep | undefined;
  const flush = () => {
    if (!first || items.length === 0) return;
    blocks.push({
      kind: "tools",
      key: `tools-${first.id}`,
      row: {
        id: `${run.id}:${first.id}`,
        version: run.rev,
        at: first.at,
        kind: "activity",
        items,
        // Every call on its own row: a run is read step by step, never folded into one line.
        settled: false,
      },
    });
    items = [];
    first = undefined;
  };
  for (const step of steps) {
    if (step.kind === "tool") {
      first ??= step;
      items.push(stepActivity(step));
    } else {
      flush();
      blocks.push({ kind: step.kind, key: step.id, step });
    }
  }
  flush();
  return blocks;
}

// Code mode: the mux's single tool runs JavaScript against the `mux` API.
// Both forms share the declarations and the sandbox module; each form
// implements the flat API methods its own way.

import type { AgentSummary } from "@mux/protocol";
import type { FunctionTool } from "./model.ts";

/** Flat methods a form implements; the sandbox wraps them as `mux.*`. */
export interface MuxApiMethods {
  machinesList(): Promise<{ id: string; name: string; os: string; online: boolean }[]>;
  agentsList(options: { machine?: string }): Promise<AgentSummary[]>;
  agentsHarnesses(options: {
    machine?: string;
  }): Promise<{ harnesses: string[]; defaultHarness: string | null }>;
  agentsSpawn(options: {
    cwd: string;
    prompt: string;
    harness?: string;
    name?: string;
    policy?: string;
    machine?: string;
  }): Promise<{ sessionId: string; name: string }>;
  agentsPrompt(options: {
    session: string;
    text: string;
    steer?: boolean;
    machine?: string;
  }): Promise<{ queued: true }>;
  agentsLast(options: { session: string; machine?: string }): Promise<{ text: string }>;
  agentsCancel(options: { session: string; machine?: string }): Promise<{ cancelled: true }>;
  memoryRecall(options: {
    pattern: string;
    limit?: number;
  }): Promise<{ index: number; line: string }[]>;
  memoryZoom(options: { lo: number; hi: number }): Promise<string[]>;
  memoryNote(text: string): Promise<{ index: number }>;
}

export const MUX_API_DECLARATIONS = `/** In scope as \`mux\`. Every method is async. */
declare const mux: {
  machines: {
    /** Machines whose link is registered. Agents run on online ones. */
    list(): Promise<{ id: string; name: string; os: string; online: boolean }[]>;
  };
  agents: {
    /** Coding-agent sessions (acpmux) on a machine. \`machine\` defaults to the only online one. */
    list(options?: { machine?: string }): Promise<{
      sessionId: string; name: string; harness: string; cwd: string;
      status: "idle" | "ready" | "running" | "waiting" | "disconnected" | "closed";
      preview: string | null; pendingPermissions: number; updatedAt: number;
    }[]>;
    /** Harness names you can pass to spawn, e.g. "claude", "codex". */
    harnesses(options?: { machine?: string }): Promise<{ harnesses: string[]; defaultHarness: string | null }>;
    /**
     * Starts an agent in \`cwd\` (absolute path) with its first prompt and returns at once.
     * When its turn ends you receive an event with its reply; do not wait or poll.
     */
    spawn(options: {
      cwd: string; prompt: string; harness?: string; name?: string;
      policy?: "ask" | "approve-reads" | "approve-edits" | "approve-all"; machine?: string;
    }): Promise<{ sessionId: string; name: string }>;
    /** Queues a prompt on a session (name or id) and returns at once; you get an event when the turn ends. \`steer\` interrupts the running turn. */
    prompt(options: { session: string; text: string; steer?: boolean; machine?: string }): Promise<{ queued: true; sessionId: string }>;
    /** The session's last reply text. */
    last(options: { session: string; machine?: string }): Promise<{ text: string }>;
    cancel(options: { session: string; machine?: string }): Promise<{ cancelled: true }>;
  };
  memory: {
    /** Log lines matching a POSIX extended regular expression (case-insensitive), newest first. Exact detail from any time. */
    recall(options: { pattern: string; limit?: number }): Promise<{ index: number; line: string }[]>;
    /** What a #lo-hi summary from your memory was made of: its two halves, or raw lines at the bottom. */
    zoom(options: { lo: number; hi: number }): Promise<string[]>;
    /** Records a fact worth keeping (a preference, a decision, a result). Messages are remembered on their own. */
    note(text: string): Promise<{ index: number }>;
  };
};`;

export const RUN_TOOL: FunctionTool = {
  type: "function",
  name: "run",
  description: `Runs JavaScript as the body of an async function in a sandbox with no network access. \`mux\` is in scope; \`return\` a JSON value to see it; console.log output is returned too. Batch several calls in one run.\n\n${MUX_API_DECLARATIONS}`,
  parameters: {
    type: "object",
    properties: { code: { type: "string", description: "Body of an async function." } },
    required: ["code"],
    additionalProperties: false,
  },
  strict: true,
};

export interface RunResult {
  ok: boolean;
  value?: unknown;
  error?: string;
  logs: string[];
}

/** Source of the sandbox module: class `Run` with `run()`, calling `env.API` for every `mux` method. */
export function runModule(code: string): string {
  return `import { WorkerEntrypoint } from "cloudflare:workers";
export class Run extends WorkerEntrypoint {
  async run() {
    const api = this.env.API;
    const logs = [];
    const show = (v) => (typeof v === "string" ? v : JSON.stringify(v));
    const console = {
      log: (...a) => logs.push(a.map(show).join(" ")),
      info: (...a) => logs.push(a.map(show).join(" ")),
      warn: (...a) => logs.push("warn: " + a.map(show).join(" ")),
      error: (...a) => logs.push("error: " + a.map(show).join(" ")),
    };
    const mux = {
      machines: { list: () => api.machinesList() },
      agents: {
        list: (o = {}) => api.agentsList(o),
        harnesses: (o = {}) => api.agentsHarnesses(o),
        spawn: (o) => api.agentsSpawn(o),
        prompt: (o) => api.agentsPrompt(o),
        last: (o) => api.agentsLast(o),
        cancel: (o) => api.agentsCancel(o),
      },
      memory: {
        recall: (o) => api.memoryRecall(o),
        zoom: (o) => api.memoryZoom(o),
        note: (text) => api.memoryNote(String(text)),
      },
    };
    try {
      const value = await (async () => {
${code}
      })();
      return { ok: true, value: value === undefined ? null : JSON.parse(JSON.stringify(value)), logs };
    } catch (error) {
      return { ok: false, error: String((error && error.stack) || error), logs };
    }
  }
}
`;
}

/** What the model sees from a run, capped so one big result cannot flood the context. */
export function formatRunResult(result: RunResult, limit = 12_000): string {
  const text = JSON.stringify(result);
  return text.length <= limit
    ? text
    : `${text.slice(0, limit)}… (${text.length - limit} more characters)`;
}

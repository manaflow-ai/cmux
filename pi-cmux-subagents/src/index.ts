import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createChildWorkspace,
  ensureParentGroup,
  piCmuxExecution,
  steerWorkspace,
} from "./cmux.js";
import type { AgentType, ChildConfig, ChildResult, RunRecord } from "./types.js";

const POLL_MS = 400;
const FOREGROUND_TIMEOUT_MS = 30 * 60 * 1000;
const AGENT_TYPES = ["Explore", "Plan", "reviewer", "worker", "general-purpose"] as const;

function safeSlug(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 32) || "agent";
}

function runId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

async function readResult(path: string): Promise<ChildResult | undefined> {
  try {
    return JSON.parse(await readFile(path, "utf8")) as ChildResult;
  } catch {
    return undefined;
  }
}

async function waitForResult(path: string, signal?: AbortSignal): Promise<ChildResult> {
  const deadline = Date.now() + FOREGROUND_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (signal?.aborted) throw new Error("Waiting cancelled. The visible subagent is still running.");
    const result = await readResult(path);
    if (result) return result;
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, POLL_MS);
      signal?.addEventListener("abort", () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
    });
  }
  throw new Error("Timed out waiting for the subagent. It remains visible in cmux.");
}

export default function piCmuxSubagents(pi: ExtensionAPI) {
  const runs = new Map<string, RunRecord>();
  const watchers = new Map<string, NodeJS.Timeout>();
  const extensionDirectory = dirname(fileURLToPath(import.meta.url));
  const launcherPath = join(extensionDirectory, "launch-child.mjs");
  const childExtensionPath = join(extensionDirectory, "child.ts");

  function watchBackground(record: RunRecord): void {
    if (watchers.has(record.id)) return;
    const timer = setInterval(async () => {
      const result = await readResult(record.resultPath);
      if (!result) return;
      clearInterval(timer);
      watchers.delete(record.id);
      record.status = result.status;
      const body = result.summary ?? result.error ?? "Subagent finished without a result.";
      pi.sendMessage({
        customType: "cmux-subagent-result",
        content: `Visible cmux subagent ${record.id} (${record.description}) ${result.status}:\n${body}`,
        display: true,
        details: { record, result },
      }, { deliverAs: "followUp", triggerTurn: true });
    }, POLL_MS);
    watchers.set(record.id, timer);
  }

  pi.registerTool({
    name: "Agent",
    label: "Visible cmux agent",
    description: "Launch a focused Pi subagent in a visible cmux workspace. The parent and children are organized in one collapsible workspace group. Foreground calls wait for the result; background calls return immediately.",
    promptSnippet: "Launch visible Pi subagents in grouped cmux workspaces",
    promptGuidelines: [
      "Use Agent when delegated work benefits from a visible, independently steerable Pi session. Use run_in_background for parallel work.",
    ],
    parameters: Type.Object({
      subagent_type: Type.Union(AGENT_TYPES.map((name) => Type.Literal(name))),
      prompt: Type.String({ description: "Self-contained task for the child agent" }),
      description: Type.String({ description: "Short workspace title" }),
      run_in_background: Type.Optional(Type.Boolean()),
      model: Type.Optional(Type.String({ description: "Optional provider/model override" })),
      thinking: Type.Optional(Type.String({ description: "Optional thinking level" })),
      cwd: Type.Optional(Type.String({ description: "Working directory, defaults to the parent cwd" })),
    }),
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      if (!process.env.CMUX_WORKSPACE_ID && !process.env.CMUX_SOCKET_PATH && !process.env.CMUX_SOCKET) {
        throw new Error("Agent requires a Pi session running inside cmux.");
      }
      const id = runId();
      const cwd = params.cwd ?? ctx.cwd;
      const sessionFile = ctx.sessionManager.getSessionFile();
      const parentKey = sessionFile ? safeSlug(sessionFile.split("/").pop() ?? "session") : "ephemeral";
      const directory = join(homedir(), ".pi", "agent", "cmux-subagents", parentKey, id);
      const resultPath = join(directory, "result.json");
      await mkdir(directory, { recursive: true });

      onUpdate?.({
        content: [{ type: "text", text: "Creating cmux workspace group…" }],
        details: {},
      });
      const executor = piCmuxExecution(pi);
      const { groupRef, parentWorkspaceRef } = await ensureParentGroup(executor, cwd);
      const config: ChildConfig & { cwd: string } = {
        id,
        task: params.prompt,
        description: params.description,
        agentType: params.subagent_type as AgentType,
        model: params.model,
        thinking: params.thinking,
        resultPath,
        childExtensionPath,
        cwd,
      };
      await writeFile(join(directory, "config.json"), `${JSON.stringify(config, null, 2)}\n`, "utf8");

      const command = `node ${JSON.stringify(launcherPath)} ${JSON.stringify(directory)}`;
      const workspaceRef = await createChildWorkspace(executor, {
        groupRef,
        cwd,
        title: `${params.subagent_type} · ${params.description}`,
        command,
        parentWorkspaceRef,
      });
      const record: RunRecord = {
        id,
        description: params.description,
        agentType: params.subagent_type as AgentType,
        cwd,
        groupRef,
        workspaceRef,
        resultPath,
        status: "running",
        startedAt: new Date().toISOString(),
      };
      runs.set(id, record);

      if (params.run_in_background) {
        watchBackground(record);
        return {
          content: [{
            type: "text",
            text: `Started visible subagent ${id} in ${workspaceRef}, under ${groupRef}.`,
          }],
          details: { record },
        };
      }

      onUpdate?.({ content: [{ type: "text", text: `Waiting for ${workspaceRef}…` }], details: record });
      const result = await waitForResult(resultPath, signal);
      record.status = result.status;
      if (result.status === "failed") throw new Error(result.error ?? "Subagent failed");
      return {
        content: [{ type: "text", text: result.summary ?? "Subagent completed without a summary." }],
        details: { record, result },
      };
    },
  });

  pi.registerTool({
    name: "get_subagent_result",
    label: "Get visible subagent result",
    description: "Check or wait for a visible cmux subagent result.",
    parameters: Type.Object({
      agent_id: Type.String(),
      wait: Type.Optional(Type.Boolean()),
    }),
    async execute(_toolCallId, params, signal) {
      const record = runs.get(params.agent_id);
      if (!record) throw new Error(`Unknown subagent: ${params.agent_id}`);
      const result = params.wait
        ? await waitForResult(record.resultPath, signal)
        : await readResult(record.resultPath);
      if (!result) {
        return {
          content: [{ type: "text", text: `${record.id} is still running in ${record.workspaceRef}.` }],
          details: { record, result: undefined as ChildResult | undefined },
        };
      }
      record.status = result.status;
      return {
        content: [{ type: "text", text: result.summary ?? result.error ?? "No result." }],
        details: { record, result },
      };
    },
  });

  pi.registerTool({
    name: "steer_subagent",
    label: "Steer visible subagent",
    description: "Send a steering message to a running Pi subagent's cmux workspace.",
    parameters: Type.Object({
      agent_id: Type.String(),
      message: Type.String(),
    }),
    async execute(_toolCallId, params) {
      const record = runs.get(params.agent_id);
      if (!record) throw new Error(`Unknown subagent: ${params.agent_id}`);
      if (record.status !== "running") throw new Error(`${record.id} is already ${record.status}`);
      await steerWorkspace(piCmuxExecution(pi), record.workspaceRef, params.message);
      return {
        content: [{ type: "text", text: `Steered ${record.id} in ${record.workspaceRef}.` }],
        details: record,
      };
    },
  });

  pi.registerCommand("cmux-agents", {
    description: "List visible cmux subagents launched by this Pi session",
    handler: async (_args, ctx) => {
      if (runs.size === 0) {
        ctx.ui.notify("No visible cmux subagents in this session.", "info");
        return;
      }
      const lines = [...runs.values()].map(
        (run) => `${run.status.padEnd(9)} ${run.id}  ${run.workspaceRef}  ${run.description}`,
      );
      ctx.ui.setWidget("pi-cmux-subagents", ["Visible cmux subagents", ...lines]);
    },
  });

  pi.on("session_shutdown", () => {
    for (const timer of watchers.values()) clearInterval(timer);
    watchers.clear();
  });
}

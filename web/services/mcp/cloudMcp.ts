// cmux Cloud as a remote MCP server (prototype). ChatGPT, Claude and other MCP
// hosts add it as a connector; the tools act only on the caller's own machines.
//
// This module is the protocol and tool layer. It never decides who owns what:
// every machine-scoped call goes through `CloudMcpGateway`, whose route binding
// runs the existing `listUserVms` / `execVm` programs, so ownership, team scope,
// plan gates and usage accounting are the same as `/api/vm`. On the machine, the
// tools speak the cmux-tui resource CLI to the session the Mac app attaches to.

import { CMUX_TUI_SESSION, cmuxTuiRunCommand, shellQuote } from "../vms/drivers/cmuxTuiDaemon";

export const CLOUD_MCP_SERVER_NAME = "cmux-cloud";
export const CLOUD_MCP_SERVER_VERSION = "0.1.0";
export const CLOUD_MCP_PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"] as const;
const LATEST_PROTOCOL_VERSION = CLOUD_MCP_PROTOCOL_VERSIONS[0];

export const CLOUD_MCP_AGENTS = ["claude", "codex", "opencode", "pi"] as const;
export type CloudMcpAgent = (typeof CLOUD_MCP_AGENTS)[number];

const MAX_TEXT_BYTES = 16 * 1024;
const MAX_OUTPUT_BYTES = 64 * 1024;
const CMUX_TUI_TIMEOUT_MS = 30_000;
// POST /api/vm/:id/exec caps a guest command at 64 KiB. execVm itself does not,
// so the check is on the full command: cmuxTuiRunCommand repeats the arguments
// once per layout branch, and quoting can triple a prompt.
const MAX_GUEST_COMMAND_BYTES = 64 * 1024;
// A batch runs its requests one after another inside one function invocation.
const MAX_BATCH_LENGTH = 8;
const MACHINE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const TERMINAL_ID_PATTERN = /^term_[A-Za-z0-9]{1,64}$/;
const WORKSPACE_ID_PATTERN = /^ws_[A-Za-z0-9]{1,64}$/;

export type CloudMcpMachine = {
  readonly id: string;
  readonly name: string | null;
  readonly status: string;
};

export type CloudMcpExecResult = {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
};

/** A failure the caller should see as a tool error, e.g. an unknown or unowned machine. */
export class CloudMcpToolError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

/**
 * The caller-bound capabilities the tools may use. Implementations are bound to
 * one authenticated caller; a machine the caller cannot reach must fail with
 * `CloudMcpToolError` before anything runs on it.
 */
export type CloudMcpGateway = {
  readonly listMachines: () => Promise<readonly CloudMcpMachine[]>;
  /** Runs `cmux-tui <args>` on the machine as its session user; `args` is already shell-quoted. */
  readonly runCmuxTui: (machineId: string, args: string, timeoutMs: number) => Promise<CloudMcpExecResult>;
};

type JsonObject = Record<string, unknown>;

type ToolAnnotations = {
  readonly title: string;
  readonly readOnlyHint: boolean;
  readonly destructiveHint: boolean;
  readonly idempotentHint: boolean;
  readonly openWorldHint: boolean;
};

type ToolDefinition = {
  readonly name: string;
  readonly description: string;
  readonly inputSchema: JsonObject;
  readonly annotations: ToolAnnotations;
};

const machineIdSchema = {
  type: "string",
  description: "Machine id from list_machines.",
};
const terminalIdSchema = {
  type: "string",
  description: "Terminal id (term_…) from list_terminals or run_agent.",
};

export const CLOUD_MCP_TOOLS: readonly ToolDefinition[] = [
  {
    name: "list_machines",
    description: "List the caller's cmux Cloud machines with their ids and status.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { title: "List machines", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "list_terminals",
    description: "List the terminals running on one of the caller's machines. Resumes the machine if it is paused.",
    inputSchema: {
      type: "object",
      properties: { machine_id: machineIdSchema },
      required: ["machine_id"],
      additionalProperties: false,
    },
    // Not read-only: like every machine call, it resumes a paused machine (billed time).
    annotations: { title: "List terminals", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "run_agent",
    description:
      "Start a coding agent (claude, codex, opencode or pi) with a one-shot prompt in a new terminal on one of the caller's machines. " +
      "Returns the terminal id; read progress with read_terminal. The terminal stays open after the agent exits.",
    inputSchema: {
      type: "object",
      properties: {
        machine_id: machineIdSchema,
        agent: { type: "string", enum: [...CLOUD_MCP_AGENTS] },
        prompt: { type: "string", description: "The task for the agent." },
      },
      required: ["machine_id", "agent", "prompt"],
      additionalProperties: false,
    },
    annotations: { title: "Run agent", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  {
    name: "read_terminal",
    description:
      "Read a terminal on one of the caller's machines. `screen` (default) is the visible screen; `output` is the recent output stream, which keeps lines that scrolled off. " +
      "Resumes the machine if it is paused.",
    inputSchema: {
      type: "object",
      properties: {
        machine_id: machineIdSchema,
        terminal_id: terminalIdSchema,
        source: { type: "string", enum: ["screen", "output"] },
      },
      required: ["machine_id", "terminal_id"],
      additionalProperties: false,
    },
    annotations: { title: "Read terminal", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "send_input",
    description:
      "Type text into a terminal on one of the caller's machines, optionally followed by Enter. What the text does depends on the program in that terminal.",
    inputSchema: {
      type: "object",
      properties: {
        machine_id: machineIdSchema,
        terminal_id: terminalIdSchema,
        text: { type: "string" },
        submit: { type: "boolean", description: "Press Enter after the text. Default false." },
      },
      required: ["machine_id", "terminal_id", "text"],
      additionalProperties: false,
    },
    annotations: { title: "Send input", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
  },
];

type ToolResult = {
  readonly content: ReadonlyArray<{ readonly type: "text"; readonly text: string }>;
  readonly structuredContent?: JsonObject;
  readonly isError?: boolean;
};

function toolSuccess(structured: JsonObject, text?: string): ToolResult {
  return {
    content: [{ type: "text", text: text ?? JSON.stringify(structured) }],
    structuredContent: structured,
  };
}

function toolFailure(code: string, message: string): ToolResult {
  return {
    content: [{ type: "text", text: message }],
    structuredContent: { error: code, message },
    isError: true,
  };
}

function requireString(args: JsonObject, key: string): string {
  const value = args[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new CloudMcpToolError("invalid_arguments", `\`${key}\` is required and must be a non-empty string.`);
  }
  return value;
}

function requireBoundedText(args: JsonObject, key: string): string {
  const value = requireString(args, key);
  if (Buffer.byteLength(value, "utf8") > MAX_TEXT_BYTES) {
    throw new CloudMcpToolError("invalid_arguments", `\`${key}\` must be ${MAX_TEXT_BYTES} bytes or smaller.`);
  }
  return value;
}

function requireMachineId(args: JsonObject): string {
  const value = requireString(args, "machine_id");
  if (!MACHINE_ID_PATTERN.test(value)) {
    throw new CloudMcpToolError("invalid_arguments", "`machine_id` is not a machine id. Use an id from list_machines.");
  }
  return value;
}

function requireTerminalId(args: JsonObject): string {
  const value = requireString(args, "terminal_id");
  if (!TERMINAL_ID_PATTERN.test(value)) {
    throw new CloudMcpToolError("invalid_arguments", "`terminal_id` must be a term_… id from list_terminals or run_agent.");
  }
  return value;
}

function rejectUnknownArguments(args: JsonObject, allowed: readonly string[]): void {
  const unknown = Object.keys(args).filter((key) => !allowed.includes(key));
  if (unknown.length > 0) {
    throw new CloudMcpToolError("invalid_arguments", `Unknown argument(s): ${unknown.join(", ")}.`);
  }
}

/** `cmux-tui --session cloud --json <words…>`, each word quoted for the guest shell. */
export function cmuxTuiArgs(words: readonly string[]): string {
  return ["--session", CMUX_TUI_SESSION, "--json", ...words].map(shellQuote).join(" ");
}

/**
 * The one-shot argv `cmux vm agent` uses for a bare prompt (CLI/CMUXCLI+VMTransfer.swift
 * vmAgentArgv), with `--` so a prompt like `--dangerously-…` stays a prompt. `pi` has no
 * documented end-of-options marker, so a leading `-` is refused for it instead.
 */
export function agentArgv(agent: CloudMcpAgent, prompt: string): string[] {
  switch (agent) {
    case "claude": return ["claude", "-p", "--", prompt];
    case "codex": return ["codex", "exec", "--", prompt];
    case "opencode": return ["opencode", "run", "--", prompt];
    case "pi":
      if (prompt.startsWith("-")) {
        throw new CloudMcpToolError("invalid_arguments", "A pi prompt cannot start with `-`.");
      }
      return ["pi", "-p", prompt];
  }
}

function guestArgsFor(words: readonly string[]): string {
  const args = cmuxTuiArgs(words);
  if (Buffer.byteLength(cmuxTuiRunCommand(args), "utf8") > MAX_GUEST_COMMAND_BYTES) {
    throw new CloudMcpToolError("invalid_arguments", "The request is too large once quoted for the machine. Shorten the prompt or text.");
  }
  return args;
}

async function runCmuxTuiJson(gateway: CloudMcpGateway, machineId: string, words: readonly string[]): Promise<unknown> {
  const args = guestArgsFor(words);
  const result = await gateway.runCmuxTui(machineId, args, CMUX_TUI_TIMEOUT_MS);
  if (result.exitCode !== 0) {
    throw new CloudMcpToolError(
      "machine_command_failed",
      `cmux on the machine exited ${result.exitCode}: ${(result.stderr || result.stdout).trim().slice(0, 2000)}`,
    );
  }
  try {
    return JSON.parse(result.stdout);
  } catch {
    throw new CloudMcpToolError("machine_command_failed", "cmux on the machine returned output that is not JSON.");
  }
}

function mutationValue(response: unknown): JsonObject {
  const value = (response as { value?: unknown } | null)?.value;
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}

function stringField(object: JsonObject, key: string, pattern: RegExp): string | null {
  const value = object[key];
  return typeof value === "string" && pattern.test(value) ? value : null;
}

async function listTerminals(gateway: CloudMcpGateway, args: JsonObject): Promise<ToolResult> {
  rejectUnknownArguments(args, ["machine_id"]);
  const machineId = requireMachineId(args);
  const listed = await runCmuxTuiJson(gateway, machineId, ["terminal", "list"]);
  const terminals = (Array.isArray(listed) ? listed : []).flatMap((entry) => {
    if (!entry || typeof entry !== "object") return [];
    const row = entry as JsonObject;
    const id = stringField(row, "id", TERMINAL_ID_PATTERN);
    if (!id) return [];
    return [{
      id,
      title: typeof row.title === "string" ? row.title : null,
      running: row.running === true,
      cwd: typeof row.cwd === "string" ? row.cwd : null,
    }];
  });
  return toolSuccess({ machine_id: machineId, terminals });
}

async function runAgent(gateway: CloudMcpGateway, args: JsonObject): Promise<ToolResult> {
  rejectUnknownArguments(args, ["machine_id", "agent", "prompt"]);
  const machineId = requireMachineId(args);
  const agent = requireString(args, "agent");
  if (!(CLOUD_MCP_AGENTS as readonly string[]).includes(agent)) {
    throw new CloudMcpToolError("invalid_arguments", `\`agent\` must be one of ${CLOUD_MCP_AGENTS.join(", ")}.`);
  }
  const prompt = requireBoundedText(args, "prompt");
  const argv = agentArgv(agent as CloudMcpAgent, prompt);
  // A login shell so the persistent-home tool paths resolve, as `cmux vm agent` does;
  // the agent argv reaches it as positional parameters, never as shell text.
  const runWords = (workspaceId: string) => [
    "workspace", workspaceId, "run", "--on-exit", "keep", "--",
    "bash", "-lc", 'cd "$HOME" && exec "$@"', "bash",
    ...argv,
  ];
  guestArgsFor(runWords(`ws_${"0".repeat(64)}`)); // refuse an oversized prompt before creating anything
  const name = `${agent} (via MCP)`;
  const created = mutationValue(await runCmuxTuiJson(gateway, machineId, ["workspace", "create", "--name", name, "--empty"]));
  const workspaceId = stringField(created, "workspace_id", WORKSPACE_ID_PATTERN);
  if (!workspaceId) {
    throw new CloudMcpToolError("machine_command_failed", "cmux on the machine did not return a workspace id.");
  }
  let terminalId: string | null = null;
  try {
    const run = mutationValue(await runCmuxTuiJson(gateway, machineId, runWords(workspaceId)));
    terminalId = stringField(run, "terminal_id", TERMINAL_ID_PATTERN);
    if (!terminalId) {
      throw new CloudMcpToolError("machine_command_failed", "cmux on the machine did not return a terminal id.");
    }
  } catch (error) {
    // Don't leave an empty workspace behind for a retry to pile onto.
    await runCmuxTuiJson(gateway, machineId, ["workspace", workspaceId, "close"]).catch(() => undefined);
    throw error;
  }
  return toolSuccess({ machine_id: machineId, agent, workspace_id: workspaceId, terminal_id: terminalId });
}

async function readTerminal(gateway: CloudMcpGateway, args: JsonObject): Promise<ToolResult> {
  rejectUnknownArguments(args, ["machine_id", "terminal_id", "source"]);
  const machineId = requireMachineId(args);
  const terminalId = requireTerminalId(args);
  const source = args.source ?? "screen";
  if (source !== "screen" && source !== "output") {
    throw new CloudMcpToolError("invalid_arguments", "`source` must be `screen` or `output`.");
  }
  if (source === "screen") {
    const screen = await runCmuxTuiJson(gateway, machineId, ["terminal", terminalId, "screen", "read"]) as JsonObject | null;
    const text = typeof screen?.text === "string" ? screen.text : "";
    return toolSuccess({ machine_id: machineId, terminal_id: terminalId, source }, text);
  }
  const output = await runCmuxTuiJson(gateway, machineId, [
    "terminal", terminalId, "output", "read", "--max-bytes", String(MAX_OUTPUT_BYTES),
  ]) as JsonObject | null;
  const text = typeof output?.text === "string" ? output.text : "";
  return toolSuccess({ machine_id: machineId, terminal_id: terminalId, source, complete: output?.complete === true }, text);
}

async function sendInput(gateway: CloudMcpGateway, args: JsonObject): Promise<ToolResult> {
  rejectUnknownArguments(args, ["machine_id", "terminal_id", "text", "submit"]);
  const machineId = requireMachineId(args);
  const terminalId = requireTerminalId(args);
  const text = requireBoundedText(args, "text");
  const submit = args.submit ?? false;
  if (typeof submit !== "boolean") {
    throw new CloudMcpToolError("invalid_arguments", "`submit` must be a boolean.");
  }
  // One write, with the Enter as a carriage return, so a failure never leaves the text typed but unsubmitted.
  await runCmuxTuiJson(gateway, machineId, ["terminal", terminalId, "write", "--text", submit ? `${text}\r` : text]);
  return toolSuccess({ machine_id: machineId, terminal_id: terminalId, sent_bytes: Buffer.byteLength(text, "utf8"), submitted: submit });
}

export async function callCloudMcpTool(gateway: CloudMcpGateway, name: string, rawArgs: unknown): Promise<ToolResult> {
  const args: JsonObject = rawArgs && typeof rawArgs === "object" && !Array.isArray(rawArgs) ? rawArgs as JsonObject : {};
  try {
    switch (name) {
      case "list_machines": {
        rejectUnknownArguments(args, []);
        const machines = await gateway.listMachines();
        return toolSuccess({ machines: machines.map((m) => ({ id: m.id, name: m.name, status: m.status })) });
      }
      case "list_terminals": return await listTerminals(gateway, args);
      case "run_agent": return await runAgent(gateway, args);
      case "read_terminal": return await readTerminal(gateway, args);
      case "send_input": return await sendInput(gateway, args);
      default: return toolFailure("unknown_tool", `Unknown tool: ${name}`);
    }
  } catch (error) {
    if (error instanceof CloudMcpToolError) return toolFailure(error.code, error.message);
    throw error;
  }
}

type JsonRpcId = string | number | null;

export type JsonRpcResponse =
  | { readonly jsonrpc: "2.0"; readonly id: JsonRpcId; readonly result: unknown }
  | { readonly jsonrpc: "2.0"; readonly id: JsonRpcId; readonly error: { readonly code: number; readonly message: string } };

function rpcError(id: JsonRpcId, code: number, message: string): JsonRpcResponse {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

/**
 * Handles one JSON-RPC message from the streamable HTTP transport. Returns null
 * for a notification or a client response, which the transport answers with 202.
 */
export async function handleCloudMcpMessage(gateway: CloudMcpGateway, message: unknown): Promise<JsonRpcResponse | null> {
  if (!message || typeof message !== "object" || Array.isArray(message)) {
    return rpcError(null, -32600, "Expected a JSON-RPC request object.");
  }
  const request = message as JsonObject;
  const id = request.id;
  const hasId = typeof id === "string" || typeof id === "number";
  if (request.jsonrpc !== "2.0") return hasId ? rpcError(id, -32600, "Expected jsonrpc 2.0.") : null;
  if (typeof request.method !== "string") return null; // a client response; nothing to answer
  if (!hasId) return null; // notifications (initialized, cancelled) need no reply
  const params = request.params && typeof request.params === "object" ? request.params as JsonObject : {};
  switch (request.method) {
    case "initialize": {
      const requested = typeof params.protocolVersion === "string" ? params.protocolVersion : "";
      const protocolVersion = (CLOUD_MCP_PROTOCOL_VERSIONS as readonly string[]).includes(requested)
        ? requested
        : LATEST_PROTOCOL_VERSION;
      return {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: CLOUD_MCP_SERVER_NAME, version: CLOUD_MCP_SERVER_VERSION },
          instructions:
            "Control the caller's cmux Cloud machines. Call list_machines first; every other tool takes a machine_id from it. " +
            "run_agent starts a coding agent in a new terminal; poll it with read_terminal.",
        },
      };
    }
    case "ping":
      return { jsonrpc: "2.0", id, result: {} };
    case "tools/list":
      return { jsonrpc: "2.0", id, result: { tools: CLOUD_MCP_TOOLS } };
    case "tools/call": {
      if (typeof params.name !== "string") return rpcError(id, -32602, "tools/call needs a tool name.");
      if (!CLOUD_MCP_TOOLS.some((tool) => tool.name === params.name)) {
        return rpcError(id, -32602, `Unknown tool: ${params.name}`);
      }
      return { jsonrpc: "2.0", id, result: await callCloudMcpTool(gateway, params.name, params.arguments) };
    }
    default:
      return rpcError(id, -32601, `Method not found: ${request.method}`);
  }
}

/**
 * Handles one POST body: a single message or, for clients on 2025-03-26, a batch.
 * An unexpected failure in one request becomes that request's -32603 reply, so a
 * client always gets JSON-RPC back; `onDefect` gets the cause for logging.
 */
export async function handleCloudMcpBody(
  gateway: CloudMcpGateway,
  body: unknown,
  onDefect: (error: unknown) => void,
): Promise<JsonRpcResponse | JsonRpcResponse[] | null> {
  const one = async (message: unknown): Promise<JsonRpcResponse | null> => {
    try {
      return await handleCloudMcpMessage(gateway, message);
    } catch (error) {
      onDefect(error);
      const id = (message as { id?: unknown } | null)?.id;
      return rpcError(typeof id === "string" || typeof id === "number" ? id : null, -32603, "Internal error");
    }
  };
  if (!Array.isArray(body)) return one(body);
  if (body.length === 0) return rpcError(null, -32600, "Empty batch.");
  if (body.length > MAX_BATCH_LENGTH) return rpcError(null, -32600, `A batch holds at most ${MAX_BATCH_LENGTH} messages.`);
  const replies: JsonRpcResponse[] = [];
  for (const message of body) {
    const reply = await one(message);
    if (reply) replies.push(reply);
  }
  return replies.length > 0 ? replies : null;
}

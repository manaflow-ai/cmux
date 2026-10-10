// Account, machine lifecycle, profile and settings tools for the cmux Cloud
// MCP server, plus the OpenAI extension metadata (UI resource, sidebar and
// thread entrypoints, settings) that `cloudMcp.ts` advertises.
//
// Billing stays where it is: a machine is created against the plan of the
// team the connection was approved for. When the plan does not include an
// action, the tool explains it and points at the informational pricing page.
// It never starts a checkout (OpenAI plugin commerce guidelines).

import { createHash, randomUUID } from "node:crypto";
import { CLOUD_MCP_AGENTS, CloudMcpToolError } from "./cloudMcpShared";
import type { CloudMcpGateway, CloudMcpMachine } from "./cloudMcp";

export const CLOUD_MCP_APP_URI = "ui://cmux/cloud-v1";
export const CLOUD_PLAN_INFO_URL = "https://cmux.com/pricing";
export const CLOUD_MCP_SETTINGS_READ_TOOL = "read_settings";
export const CLOUD_MCP_SETTINGS_UPDATE_TOOL = "update_settings";

/** GB sizes offered to the model; the server maps them to the plan's memory ladder. */
export const CLOUD_MCP_MACHINE_SIZES_GB = [4, 8, 16, 24, 32, 64] as const;

const MACHINE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const MAX_DISPLAY_NAME_LENGTH = 64;

type JsonObject = Record<string, unknown>;

export type CloudMcpAccount = {
  readonly planId: string | null;
  readonly teamName: string | null;
  readonly maxActiveVms: number | null;
  readonly activeVmCount: number | null;
  readonly memoryOptionsMb: readonly number[];
};

export type CloudMcpProfile = {
  readonly id: string;
  readonly name?: string;
  readonly email?: string;
  readonly nickname?: string;
};

export type CloudMcpSettings = {
  readonly default_agent: (typeof CLOUD_MCP_AGENTS)[number];
  readonly default_size_gb: string;
  readonly auto_pause_after_agent: boolean;
};

export const DEFAULT_CLOUD_MCP_SETTINGS: CloudMcpSettings = {
  default_agent: "codex",
  default_size_gb: "8",
  auto_pause_after_agent: false,
};

/** A stable, opaque profile id for one (user, billing team) connection. */
export function cloudMcpProfileId(userId: string, teamId: string | null): string {
  return `cmux_${createHash("sha256").update(`${userId}\u0000${teamId ?? ""}`).digest("hex").slice(0, 32)}`;
}

const APP_ICON_SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.33" stroke-linecap="round" stroke-linejoin="round">' +
  '<rect x="2.5" y="3.5" width="15" height="13" rx="2"/><path d="M6 8l2.5 2L6 12"/><path d="M10.5 12.5h3.5"/></svg>';
const APP_ICON = {
  src: `data:image/svg+xml;base64,${Buffer.from(APP_ICON_SVG).toString("base64")}`,
  mimeType: "image/svg+xml",
  sizes: ["20x20"],
};

const machineIdSchema = { type: "string", description: "Machine id from list_machines." };

const accountSchema = {
  type: "object",
  properties: {
    plan: { type: ["string", "null"] },
    team: { type: ["string", "null"] },
    machine_limit: { type: ["integer", "null"] },
    active_machines: { type: ["integer", "null"] },
    sizes_gb: { type: "array", items: { type: "integer" } },
    cloud_included: { type: "boolean" },
    plan_info_url: { type: "string" },
  },
  required: ["plan", "cloud_included", "plan_info_url"],
};

const machineSchema = {
  type: "object",
  properties: {
    id: { type: "string" },
    name: { type: ["string", "null"] },
    status: { type: "string" },
  },
  required: ["id", "status"],
};

const profileOutputSchema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  type: "object",
  properties: {
    id: {
      type: "string",
      minLength: 1,
      pattern: "\\S",
      description: "Opaque profile identifier, unique within this app and unchanged across token refresh, reconnection, and display-metadata changes. Never reassigned to another profile.",
    },
    name: { type: "string", description: "Display name for the authenticated profile." },
    email: { type: "string", description: "Email address for display; not used as the profile identity." },
    nickname: { type: "string", description: "A useful label that helps users distinguish connected profiles." },
  },
  required: ["id"],
  additionalProperties: false,
};

const settingsSchema = {
  type: "object",
  properties: {
    default_agent: {
      type: "string",
      title: "Default agent",
      description: "The coding agent run_agent starts when you do not name one.",
      enum: [...CLOUD_MCP_AGENTS],
    },
    default_size_gb: {
      type: "string",
      title: "Default machine size (GB memory)",
      description: "The size new machines get when you do not name one. Your plan limits which sizes are available.",
      enum: CLOUD_MCP_MACHINE_SIZES_GB.map(String),
    },
    auto_pause_after_agent: {
      type: "boolean",
      title: "Suggest pausing idle machines",
      description: "After an agent finishes, offer to pause its machine so it stops using plan time.",
    },
  },
  required: ["default_agent", "default_size_gb", "auto_pause_after_agent"],
};

const settingsLayout = [
  {
    kind: "group",
    title: "Machines and agents",
    items: [
      { kind: "property", property: "default_agent" },
      { kind: "property", property: "default_size_gb" },
      { kind: "property", property: "auto_pause_after_agent" },
    ],
  },
  {
    kind: "group",
    title: "Account",
    items: [
      { kind: "tool", tool: "get_account", title: "Show plan and limits", description: "The plan and machine limits of the connected team." },
    ],
  },
];

function oauth(scopes: readonly string[]) {
  return [{ type: "oauth2", scopes: [...scopes] }];
}

function uiMeta(extra: JsonObject = {}): JsonObject {
  return { ui: { resourceUri: CLOUD_MCP_APP_URI }, "openai/outputTemplate": CLOUD_MCP_APP_URI, ...extra };
}

/** Tool definitions this module adds, in `tools/list` order, with the scope each needs. */
export const CLOUD_MCP_CLOUD_TOOLS = [
  {
    name: "open_cloud",
    title: "cmux Cloud",
    requiredScope: "machines:read",
    description: "Open the cmux Cloud view: the caller's machines, their status, and the plan's machine limits.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    outputSchema: { type: "object", properties: { account: accountSchema, machines: { type: "array", items: machineSchema } }, required: ["account", "machines"] },
    annotations: { title: "cmux Cloud", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    icons: [APP_ICON],
    securitySchemes: oauth(["machines:read"]),
    _meta: uiMeta({ "openai/ui": { entrypoints: [{ type: "global" }, { type: "thread" }] } }),
  },
  {
    name: "get_account",
    title: "Get plan and limits",
    requiredScope: "machines:read",
    description: "Show the connected team's cmux plan, its machine limit, how many machines are active, and the machine sizes the plan allows.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    outputSchema: accountSchema,
    annotations: { title: "Get plan and limits", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    securitySchemes: oauth(["machines:read"]),
  },
  {
    name: "create_machine",
    title: "Create machine",
    requiredScope: "machines:write",
    description:
      "Create a new cmux Cloud machine (a Linux VM with Claude Code, Codex, OpenCode and Pi installed) on the connected team's plan. " +
      "Use only when the user asks for a new machine.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: `Optional display name, up to ${MAX_DISPLAY_NAME_LENGTH} characters.` },
        size_gb: { type: "integer", enum: [...CLOUD_MCP_MACHINE_SIZES_GB], description: "Memory in GB. Omit to use the default size from settings." },
      },
      additionalProperties: false,
    },
    outputSchema: { type: "object", properties: { machine: machineSchema }, required: ["machine"] },
    annotations: { title: "Create machine", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    securitySchemes: oauth(["machines:write"]),
    _meta: uiMeta(),
  },
  {
    name: "pause_machine",
    title: "Pause machine",
    requiredScope: "machines:write",
    description: "Pause one of the caller's machines. Running programs stop; files and the home directory stay. Resume it later with resume_machine.",
    inputSchema: { type: "object", properties: { machine_id: machineIdSchema }, required: ["machine_id"], additionalProperties: false },
    outputSchema: { type: "object", properties: { machine: machineSchema }, required: ["machine"] },
    annotations: { title: "Pause machine", readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    securitySchemes: oauth(["machines:write"]),
  },
  {
    name: "resume_machine",
    title: "Resume machine",
    requiredScope: "machines:write",
    description: "Resume a paused machine.",
    inputSchema: { type: "object", properties: { machine_id: machineIdSchema }, required: ["machine_id"], additionalProperties: false },
    outputSchema: { type: "object", properties: { machine: machineSchema }, required: ["machine"] },
    annotations: { title: "Resume machine", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    securitySchemes: oauth(["machines:write"]),
  },
  {
    name: "delete_machine",
    title: "Delete machine",
    requiredScope: "machines:write",
    description: "Permanently delete one of the caller's machines and everything on it. This cannot be undone. Confirm the machine with the user first.",
    inputSchema: { type: "object", properties: { machine_id: machineIdSchema }, required: ["machine_id"], additionalProperties: false },
    outputSchema: { type: "object", properties: { deleted: { type: "string" } }, required: ["deleted"] },
    annotations: { title: "Delete machine", readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    securitySchemes: oauth(["machines:write"]),
  },
  {
    name: "get_profile",
    title: "Get connected account",
    requiredScope: null,
    description:
      "Return the profile represented by this request's authenticated credentials. The opaque id is unique within this app and remains unchanged across token refresh, reconnection, and display-metadata changes.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    outputSchema: profileOutputSchema,
    annotations: { title: "Get connected account", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    securitySchemes: oauth([]),
    _meta: { "openai/profile": true },
  },
  {
    name: CLOUD_MCP_SETTINGS_READ_TOOL,
    title: "Read settings",
    requiredScope: null,
    description: "Read this connection's cmux preferences: default agent, default machine size, and idle-machine suggestions.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    outputSchema: {
      type: "object",
      properties: { schema: { type: "object" }, values: { type: "object" }, layout: { type: "array" } },
      required: ["schema", "values"],
    },
    annotations: { title: "Read settings", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    securitySchemes: oauth([]),
  },
  {
    name: CLOUD_MCP_SETTINGS_UPDATE_TOOL,
    title: "Update settings",
    requiredScope: null,
    description: "Change this connection's cmux preferences. Only the given settings change.",
    inputSchema: {
      type: "object",
      properties: {
        set: {
          type: "object",
          properties: settingsSchema.properties,
          minProperties: 1,
          additionalProperties: false,
        },
      },
      required: ["set"],
      additionalProperties: false,
    },
    outputSchema: { type: "object", properties: { values: { type: "object" } }, required: ["values"] },
    annotations: { title: "Update settings", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    securitySchemes: oauth([]),
  },
] as const;

export type CloudMcpCloudToolName = (typeof CLOUD_MCP_CLOUD_TOOLS)[number]["name"];

type ToolResult = {
  readonly content: ReadonlyArray<{ readonly type: "text"; readonly text: string }>;
  readonly structuredContent?: JsonObject;
  readonly isError?: boolean;
  readonly _meta?: JsonObject;
};

function success(structured: JsonObject, text: string, meta?: JsonObject): ToolResult {
  return { content: [{ type: "text", text }], structuredContent: structured, ...(meta ? { _meta: meta } : {}) };
}

function machineIdFrom(args: JsonObject): string {
  const value = args.machine_id;
  if (typeof value !== "string" || !MACHINE_ID_PATTERN.test(value)) {
    throw new CloudMcpToolError("invalid_arguments", "`machine_id` is not a machine id. Use an id from list_machines.");
  }
  return value;
}

function rejectUnknown(args: JsonObject, allowed: readonly string[]): void {
  const unknown = Object.keys(args).filter((key) => !allowed.includes(key));
  if (unknown.length > 0) throw new CloudMcpToolError("invalid_arguments", `Unknown argument(s): ${unknown.join(", ")}.`);
}

/** Whether the plan includes Cloud machines at all; free plans do not. */
export function cloudIncluded(account: CloudMcpAccount): boolean {
  return (account.maxActiveVms ?? 0) > 0;
}

export function accountStructure(account: CloudMcpAccount): JsonObject {
  return {
    plan: account.planId,
    team: account.teamName,
    machine_limit: account.maxActiveVms,
    active_machines: account.activeVmCount,
    sizes_gb: account.memoryOptionsMb.map((mb) => Math.round(mb / 1024)),
    cloud_included: cloudIncluded(account),
    plan_info_url: CLOUD_PLAN_INFO_URL,
  };
}

function accountText(account: CloudMcpAccount): string {
  const team = account.teamName ? ` for ${account.teamName}` : "";
  if (!cloudIncluded(account)) {
    return `The ${account.planId ?? "current"} plan${team} does not include Cloud machines. Plans are described at ${CLOUD_PLAN_INFO_URL}.`;
  }
  return `Plan ${account.planId ?? "unknown"}${team}: ${account.activeVmCount ?? 0} of ${account.maxActiveVms} machines active.`;
}

function machineStructure(machine: CloudMcpMachine): JsonObject {
  return { id: machine.id, name: machine.name, status: machine.status };
}

export function settingsValues(stored: Record<string, unknown>): CloudMcpSettings {
  const agent = stored.default_agent;
  const size = stored.default_size_gb;
  return {
    default_agent: (CLOUD_MCP_AGENTS as readonly unknown[]).includes(agent) ? agent as CloudMcpSettings["default_agent"] : DEFAULT_CLOUD_MCP_SETTINGS.default_agent,
    default_size_gb: CLOUD_MCP_MACHINE_SIZES_GB.map(String).includes(size as string) ? size as string : DEFAULT_CLOUD_MCP_SETTINGS.default_size_gb,
    auto_pause_after_agent: typeof stored.auto_pause_after_agent === "boolean" ? stored.auto_pause_after_agent : DEFAULT_CLOUD_MCP_SETTINGS.auto_pause_after_agent,
  };
}

function validatedSettingsUpdate(raw: unknown): Partial<CloudMcpSettings> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw) || Object.keys(raw).length === 0) {
    throw new CloudMcpToolError("invalid_arguments", "`set` must name at least one setting.");
  }
  const set = raw as JsonObject;
  rejectUnknown(set, Object.keys(settingsSchema.properties));
  const merged = settingsValues({ ...DEFAULT_CLOUD_MCP_SETTINGS, ...set });
  for (const [key, value] of Object.entries(set)) {
    if (merged[key as keyof CloudMcpSettings] !== value) {
      throw new CloudMcpToolError("invalid_arguments", `\`${key}\` has an unsupported value.`);
    }
  }
  return set as Partial<CloudMcpSettings>;
}

async function openCloud(gateway: CloudMcpGateway): Promise<ToolResult> {
  const [account, machines] = await Promise.all([gateway.account(), gateway.listMachines()]);
  return success(
    { view: "cloud", account: accountStructure(account), machines: machines.map(machineStructure) },
    `${accountText(account)} ${machines.length} machine(s).`,
  );
}

async function createMachine(gateway: CloudMcpGateway, args: JsonObject): Promise<ToolResult> {
  rejectUnknown(args, ["name", "size_gb"]);
  const name = args.name;
  if (name !== undefined && (typeof name !== "string" || name.trim().length === 0 || name.length > MAX_DISPLAY_NAME_LENGTH)) {
    throw new CloudMcpToolError("invalid_arguments", `\`name\` must be 1 to ${MAX_DISPLAY_NAME_LENGTH} characters.`);
  }
  let sizeGb = args.size_gb;
  if (sizeGb === undefined) sizeGb = Number(settingsValues(await gateway.readSettings()).default_size_gb);
  if (!(CLOUD_MCP_MACHINE_SIZES_GB as readonly unknown[]).includes(sizeGb)) {
    throw new CloudMcpToolError("invalid_arguments", `\`size_gb\` must be one of ${CLOUD_MCP_MACHINE_SIZES_GB.join(", ")}.`);
  }
  const machine = await gateway.createMachine({
    displayName: typeof name === "string" ? name.trim() : null,
    memoryMb: (sizeGb as number) * 1024,
    idempotencyKey: randomUUID(),
  });
  return success({ view: "machine", machine: machineStructure(machine) }, `Created machine ${machine.name ?? machine.id} (${machine.id}), status ${machine.status}.`);
}

async function machineState(gateway: CloudMcpGateway, args: JsonObject, action: "pause" | "resume"): Promise<ToolResult> {
  rejectUnknown(args, ["machine_id"]);
  const machine = await gateway.setMachineState(machineIdFrom(args), action);
  return success({ machine: machineStructure(machine) }, `Machine ${machine.id} is ${machine.status}.`);
}

async function deleteMachine(gateway: CloudMcpGateway, args: JsonObject): Promise<ToolResult> {
  rejectUnknown(args, ["machine_id"]);
  const machineId = machineIdFrom(args);
  await gateway.deleteMachine(machineId);
  return success({ deleted: machineId }, `Deleted machine ${machineId}.`);
}

async function readSettings(gateway: CloudMcpGateway): Promise<ToolResult> {
  const values = settingsValues(await gateway.readSettings());
  return success({ schema: settingsSchema, values, layout: settingsLayout }, JSON.stringify(values));
}

async function updateSettings(gateway: CloudMcpGateway, args: JsonObject): Promise<ToolResult> {
  rejectUnknown(args, ["set"]);
  const update = validatedSettingsUpdate(args.set);
  const values = { ...settingsValues(await gateway.readSettings()), ...update };
  await gateway.writeSettings(values);
  return success({ values }, JSON.stringify(values));
}

export async function callCloudMcpCloudTool(
  gateway: CloudMcpGateway,
  name: CloudMcpCloudToolName,
  args: JsonObject,
): Promise<ToolResult> {
  switch (name) {
    case "open_cloud":
      rejectUnknown(args, []);
      return openCloud(gateway);
    case "get_account": {
      rejectUnknown(args, []);
      const account = await gateway.account();
      return success(accountStructure(account), accountText(account));
    }
    case "create_machine": return createMachine(gateway, args);
    case "pause_machine": return machineState(gateway, args, "pause");
    case "resume_machine": return machineState(gateway, args, "resume");
    case "delete_machine": return deleteMachine(gateway, args);
    case "get_profile": {
      rejectUnknown(args, []);
      const profile = await gateway.profile();
      return success({ ...profile }, profile.nickname ?? profile.email ?? profile.id);
    }
    case CLOUD_MCP_SETTINGS_READ_TOOL: return readSettings(gateway);
    case CLOUD_MCP_SETTINGS_UPDATE_TOOL: return updateSettings(gateway, args);
  }
}

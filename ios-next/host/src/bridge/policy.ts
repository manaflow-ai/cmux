// Default-deny policy for everything the bridge sends to the cmux-next
// daemon and to acpmux. The bridge never forwards phone JSON: each phone RPC
// is mapped by host code to one of these calls, and every outgoing call is
// checked here first (defense in depth). See BRIDGE-SECURITY.md.

export class PolicyError extends Error {
  constructor(message: string) {
    super(`bridge policy: ${message}`);
  }
}

type FieldRule = (value: unknown) => boolean;

const isSurface: FieldRule = (v) => typeof v === "number" && Number.isInteger(v) && v >= 0;
const isString = (max: number): FieldRule => (v) => typeof v === "string" && v.length <= max;
const isBase64 = (max: number): FieldRule => (v) => typeof v === "string" && v.length <= max && /^[A-Za-z0-9+/=]*$/.test(v);
const isStringArray: FieldRule = (v) => Array.isArray(v) && v.every((x) => typeof x === "string" && x.length <= 128);
const anything: FieldRule = () => true;

/**
 * Daemon commands and the only fields each may carry. Absent here means
 * denied. Command-bearing fields (argv, command, shell_args, cwd, env,
 * terminal_id, launch specs) appear nowhere, and no command that executes a
 * process with caller-chosen arguments (run, create-terminal,
 * create-surface-with-receipt, apply-layout, split/new-pane with shell_args)
 * is listed.
 */
export const DAEMON_ALLOW: Record<string, Record<string, FieldRule>> = {
  identify: {},
  "set-client-info": { name: isString(128), kind: (v) => v === "frontend", capabilities: isStringArray, device_kind: isString(32), device_name: isString(128) },
  subscribe: { tree_events: (v) => v === "deltas" },
  "list-workspaces": {},
  // Byte stream only: the phone's Ghostty consumes raw VT. No cols/rows, so
  // attaching never takes the Mac's grid.
  "attach-surface": { surface: isSurface, mode: (v) => v === "bytes" },
  // Only ever opt the bridge's view out of sizing.
  "set-size-counts": { surface: isSurface, counts: (v) => v === false },
  "detach-attached-view": { surface: isSurface, lease: isString(256) },
  send: { surface: isSurface, bytes: isBase64(1024 * 1024) },
  // A plain new tab runs the user's default shell (no cwd/env/shell_args).
  "new-tab": {},
  "close-surface": { surface: isSurface },
  "rename-surface": { surface: isSurface, name: isString(256) },
};

/** acpmux JSON-RPC methods the bridge may call, with their allowed params. */
export const ACPMUX_ALLOW: Record<string, Record<string, FieldRule>> = {
  initialize: { protocolVersion: anything, clientCapabilities: (v) => typeof v === "object" && v !== null && Object.keys(v).length === 0, clientInfo: anything },
  "_acpmux/watch": { enabled: (v) => typeof v === "boolean" },
  "_acpmux/sessions": {},
  "_acpmux/harnesses": {},
  "_acpmux/models": {},
  // cwd is validated by safeCwd (inside $HOME); mcpServers must be empty (no
  // phone-chosen MCP server commands); _meta may carry only harness/model.
  "session/new": {
    cwd: isString(4096),
    mcpServers: (v) => Array.isArray(v) && v.length === 0,
    _meta: (v) => {
      const a = (v as { acpmux?: Record<string, unknown> })?.acpmux;
      return !!a && Object.keys(v as object).length === 1 && Object.keys(a).every((k) => k === "harness" || k === "model") && Object.values(a).every((x) => typeof x === "string" && x.length <= 128);
    },
  },
  "_acpmux/attach": { sessionId: isString(128), kinds: isStringArray, eventStream: (v) => v === true, limit: (v) => typeof v === "number" && v <= 5000 },
  "session/prompt": { sessionId: isString(128), prompt: (v) => Array.isArray(v) && v.every((b: any) => b && (b.type === "text" || b.type === "image")) },
  "session/cancel": { sessionId: isString(128) },
  "_acpmux/kill": { sessionId: isString(128) },
  "_acpmux/permission_respond": { sessionId: isString(128), permissionId: isString(256), optionId: isString(256) },
  "session/set_model": { sessionId: isString(128), modelId: isString(256) },
  "session/set_mode": { sessionId: isString(128), modeId: isString(128) },
  "_acpmux/rename": { sessionId: isString(128), newName: isString(256) },
};

function check(table: Record<string, Record<string, FieldRule>>, what: string, name: string, params: Record<string, unknown>): void {
  const rules = Object.prototype.hasOwnProperty.call(table, name) ? table[name] : undefined;
  if (!rules) throw new PolicyError(`${what} ${name} is not allowed`);
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined) continue;
    const rule = Object.prototype.hasOwnProperty.call(rules, k) ? rules[k] : undefined;
    if (!rule) throw new PolicyError(`${what} ${name}: field ${k} is not allowed`);
    if (!rule(v)) throw new PolicyError(`${what} ${name}: field ${k} has a disallowed value`);
  }
}

export function checkDaemonCommand(cmd: string, params: Record<string, unknown>): void {
  check(DAEMON_ALLOW, "daemon command", cmd, params);
}

export function checkAcpmuxCall(method: string, params: Record<string, unknown>): void {
  check(ACPMUX_ALLOW, "acpmux method", method, params);
}

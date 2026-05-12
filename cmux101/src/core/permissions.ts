/**
 * Permissions: resolves tool permission levels for cmux101.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Permissions, PermissionLevel } from "./types.js";

// ----------------------------------------------------------------------------
// Permission modes
// ----------------------------------------------------------------------------

export type PermissionMode =
  | "default"
  | "auto"
  | "plan"
  | "read-only"
  | "workspace-write"
  | "danger-full-access";

const READ_ONLY_TOOLS: string[] = [
  "file_read",
  "glob",
  "grep",
  "web_fetch",
  "web_search",
  "cmux_tree",
  "cmux_read_screen",
  "cmux_list_workspaces",
  "cmux_current_workspace",
  "cmux_list_panes",
  "cmux_top",
  "todo_list",
  "config_read",
  "memory_list",
];

/**
 * Returns a new PermissionResolver with mode-driven allow/deny rules layered
 * on top of the existing resolver.
 */
export function applyPermissionMode(
  resolver: PermissionResolver,
  mode: PermissionMode,
): PermissionResolver {
  if (mode === "default") {
    // No override — return resolver unchanged.
    return resolver;
  }

  if (mode === "auto" || mode === "danger-full-access") {
    // Allow everything.
    return new PermissionResolver({
      allow: ["*"],
      ask: [],
      deny: [],
      defaults: new Map(),
      askUser: resolver["_askUser"],
      cwd: resolver["_cwd"],
    });
  }

  if (mode === "read-only" || mode === "plan") {
    // Allow only the read-only tool set; deny everything else.
    return new PermissionResolver({
      allow: [...READ_ONLY_TOOLS],
      ask: [],
      deny: [],
      defaults: new Map(),
      askUser: resolver["_askUser"],
      cwd: resolver["_cwd"],
      _narrowMode: true,
    });
  }

  if (mode === "workspace-write") {
    // Allow read-only tools + file_write/file_edit; ask for shell; deny the rest.
    return new PermissionResolver({
      allow: [...READ_ONLY_TOOLS, "file_write", "file_edit"],
      ask: ["shell"],
      deny: [],
      defaults: new Map(),
      askUser: resolver["_askUser"],
      cwd: resolver["_cwd"],
    });
  }

  // Unreachable, but satisfy TS.
  return resolver;
}

// ----------------------------------------------------------------------------
// Glob helper
// ----------------------------------------------------------------------------

/** Matches a glob pattern supporting `*` (any sequence of non-separator chars)
 *  and exact match. No path separators in tool names so `*` matches everything.
 */
export function matchGlob(pattern: string, name: string): boolean {
  if (!pattern.includes("*")) {
    return pattern === name;
  }
  // Convert glob to regex: escape special chars, replace * with .*
  const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  const re = new RegExp(`^${escaped}$`);
  return re.test(name);
}

// ----------------------------------------------------------------------------
// PermissionResolver
// ----------------------------------------------------------------------------

export interface PermissionResolverOptions {
  allow?: string[];
  ask?: string[];
  deny?: string[];
  /** Tool default permissions keyed by tool name. */
  defaults?: Map<string, PermissionLevel>;
  /** Callback to prompt the user. Used by the runner's TUI. */
  askUser: (toolName: string, input: unknown) => Promise<PermissionLevel>;
  /** Working directory — used to persist project-scoped permissions. */
  cwd?: string;
  /**
   * When true, the resolver is in "narrow" mode: only explicitly allowed
   * tools are permitted; everything else is denied.
   */
  _narrowMode?: boolean;
}

export class PermissionResolver implements Permissions {
  private _allow: string[];
  private _ask: string[];
  private _deny: string[];
  private _defaults: Map<string, PermissionLevel>;
  private _askUser: (toolName: string, input: unknown) => Promise<PermissionLevel>;
  private _cwd: string | undefined;

  /** In-memory session overrides: toolName -> level */
  private _sessionMap: Map<string, PermissionLevel> = new Map();
  private _narrowMode: boolean;

  constructor(opts: PermissionResolverOptions) {
    this._allow = opts.allow ?? [];
    this._ask = opts.ask ?? [];
    this._deny = opts.deny ?? [];
    this._defaults = opts.defaults ?? new Map();
    this._askUser = opts.askUser;
    this._cwd = opts.cwd;
    this._narrowMode = opts._narrowMode ?? false;
  }

  private _matchesList(list: string[], toolName: string): boolean {
    return list.some((pattern) => matchGlob(pattern, toolName));
  }

  resolve(toolName: string, _input: unknown): PermissionLevel {
    // 1. Session / project remembered values take highest priority
    if (this._sessionMap.has(toolName)) {
      return this._sessionMap.get(toolName)!;
    }

    // Narrow mode: allow-list first, then deny everything else
    if (this._narrowMode) {
      if (this._matchesList(this._allow, toolName)) return "allow";
      return "deny";
    }

    // 2. Deny list (exact or glob)
    if (this._matchesList(this._deny, toolName)) return "deny";

    // 3. Allow list
    if (this._matchesList(this._allow, toolName)) return "allow";

    // 4. Ask list
    if (this._matchesList(this._ask, toolName)) return "ask";

    // 5. Tool default from registry defaults map
    if (this._defaults.has(toolName)) {
      return this._defaults.get(toolName)!;
    }

    // 6. Fallback
    return "ask";
  }

  remember(toolName: string, level: PermissionLevel, scope?: "session" | "project"): void {
    this._sessionMap.set(toolName, level);

    if (scope === "project" && this._cwd) {
      // Persist to <cwd>/.cmux101/permissions.json
      const permDir = join(this._cwd, ".cmux101");
      if (!existsSync(permDir)) {
        mkdirSync(permDir, { recursive: true });
      }
      const permPath = join(permDir, "permissions.json");
      let existing: Record<string, PermissionLevel> = {};
      try {
        if (existsSync(permPath)) {
          existing = JSON.parse(readFileSync(permPath, "utf8"));
        }
      } catch {
        // ignore
      }
      existing[toolName] = level;
      writeFileSync(permPath, JSON.stringify(existing, null, 2));
    }
  }

  narrow(allowedTools: string[]): Permissions {
    return new PermissionResolver({
      allow: allowedTools,
      ask: [],
      deny: [],
      defaults: new Map(),
      askUser: this._askUser,
      cwd: this._cwd,
      _narrowMode: true,
    });
  }

  /** Prompt the user for a permission decision. */
  async askUserFor(toolName: string, input: unknown): Promise<PermissionLevel> {
    return this._askUser(toolName, input);
  }
}

// ----------------------------------------------------------------------------
// Factory
// ----------------------------------------------------------------------------

export function createPermissionResolver(
  options: PermissionResolverOptions,
): PermissionResolver {
  return new PermissionResolver(options);
}

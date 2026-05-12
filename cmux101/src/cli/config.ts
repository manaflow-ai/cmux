/**
 * Config loading and writing for cmux101.
 *
 * Merge order (later overrides earlier):
 *   1. ~/.cmux101/config.json
 *   2. <cwd>/.cmux101/config.json
 *   3. opts.configPath (explicit override)
 */

import { z } from "zod";
import { join } from "node:path";
import { mkdir } from "node:fs/promises";
import type { Config } from "@/core/types";

// ---------------------------------------------------------------------------
// Zod schema
// ---------------------------------------------------------------------------

const HookConfigSchema = z.object({
  event: z.enum([
    "session.start",
    "session.end",
    "user.message",
    "assistant.message",
    "tool.pre",
    "tool.post",
    "permission.ask",
  ]),
  command: z.string(),
  matcher: z.string().optional(),
});

const McpServerConfigSchema = z.object({
  name: z.string(),
  transport: z.enum(["stdio", "sse", "http"]),
  command: z.string().optional(),
  args: z.array(z.string()).optional(),
  url: z.string().optional(),
  env: z.record(z.string()).optional(),
});

const PermissionsSchema = z.object({
  allow: z.array(z.string()).optional(),
  ask: z.array(z.string()).optional(),
  deny: z.array(z.string()).optional(),
});

const ConfigSchema = z.object({
  defaultProvider: z.string(),
  defaultModel: z.string(),
  providers: z.record(z.record(z.unknown())),
  hooks: z.array(HookConfigSchema).optional(),
  mcp: z.array(McpServerConfigSchema).optional(),
  permissions: PermissionsSchema.optional(),
  aliases: z.record(z.string()).optional(),
});

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

const DEFAULT_CONFIG: Config = {
  defaultProvider: "anthropic",
  defaultModel: "claude-opus-4-7",
  providers: {},
  permissions: {
    ask: ["shell", "file_write", "file_edit"],
    allow: ["file_read", "glob", "grep", "web_fetch"],
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function userConfigPath(): string {
  const home = process.env.HOME ?? process.env.USERPROFILE ?? "~";
  return join(home, ".cmux101", "config.json");
}

function projectConfigPath(cwd: string): string {
  return join(cwd, ".cmux101", "config.json");
}

async function readJsonFile(path: string): Promise<Record<string, unknown> | null> {
  try {
    const file = Bun.file(path);
    const exists = await file.exists();
    if (!exists) return null;
    const text = await file.text();
    const raw = JSON.parse(text) as Record<string, unknown>;
    return expandEnvInRecord(raw);
  } catch {
    return null;
  }
}

function mergeArrayField<T>(base: T[] | undefined, override: T[] | undefined): T[] | undefined {
  if (!override) return base;
  if (!base) return override;
  return [...base, ...override];
}

// ---------------------------------------------------------------------------
// Environment variable expansion
// ---------------------------------------------------------------------------

/**
 * Replace `${FOO}` placeholders with `process.env.FOO` (empty string if unset).
 * Applied recursively to all string values in config objects.
 */
export function expandEnv(str: string): string {
  return str.replace(/\$\{([^}]+)\}/g, (_, name: string) => process.env[name] ?? "");
}

function expandEnvInValue(value: unknown): unknown {
  if (typeof value === "string") return expandEnv(value);
  if (Array.isArray(value)) return value.map(expandEnvInValue);
  if (value !== null && typeof value === "object") {
    const result: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      result[k] = expandEnvInValue(v);
    }
    return result;
  }
  return value;
}

function expandEnvInRecord(raw: Record<string, unknown>): Record<string, unknown> {
  return expandEnvInValue(raw) as Record<string, unknown>;
}

function mergeConfigs(base: Config, override: Partial<Config>): Config {
  return {
    defaultProvider: override.defaultProvider ?? base.defaultProvider,
    defaultModel: override.defaultModel ?? base.defaultModel,
    providers: { ...base.providers, ...override.providers },
    hooks: mergeArrayField(base.hooks, override.hooks),
    mcp: mergeArrayField(base.mcp, override.mcp),
    permissions: override.permissions
      ? {
          allow: mergeArrayField(base.permissions?.allow, override.permissions.allow),
          ask: mergeArrayField(base.permissions?.ask, override.permissions.ask),
          deny: mergeArrayField(base.permissions?.deny, override.permissions.deny),
        }
      : base.permissions,
    aliases: override.aliases
      ? { ...(base.aliases ?? {}), ...override.aliases }
      : base.aliases,
  };
}

function parseAndValidate(raw: Record<string, unknown>, sourcePath: string): Partial<Config> {
  const result = ConfigSchema.partial().safeParse(raw);
  if (!result.success) {
    const messages = result.error.issues
      .map((i) => `  ${i.path.join(".")}: ${i.message}`)
      .join("\n");
    throw new Error(`Invalid config at ${sourcePath}:\n${messages}`);
  }
  return result.data as Partial<Config>;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export async function loadConfig(opts?: {
  cwd?: string;
  configPath?: string;
}): Promise<Config> {
  const cwd = opts?.cwd ?? process.cwd();
  let config: Config = { ...DEFAULT_CONFIG, permissions: { ...DEFAULT_CONFIG.permissions } };

  const paths: Array<{ path: string; label: string }> = [
    { path: userConfigPath(), label: "user" },
    { path: projectConfigPath(cwd), label: "project" },
  ];
  if (opts?.configPath) {
    paths.push({ path: opts.configPath, label: "explicit" });
  }

  for (const { path, label } of paths) {
    const raw = await readJsonFile(path);
    if (raw == null) continue;
    const partial = parseAndValidate(raw, `${label} config (${path})`);
    config = mergeConfigs(config, partial);
  }

  return config;
}

export async function writeConfig(config: Config, scope: "user" | "project"): Promise<void> {
  let targetPath: string;
  if (scope === "user") {
    targetPath = userConfigPath();
  } else {
    targetPath = projectConfigPath(process.cwd());
  }

  // Validate before writing
  const result = ConfigSchema.safeParse(config);
  if (!result.success) {
    const messages = result.error.issues
      .map((i) => `  ${i.path.join(".")}: ${i.message}`)
      .join("\n");
    throw new Error(`Cannot write invalid config:\n${messages}`);
  }

  const dir = targetPath.substring(0, targetPath.lastIndexOf("/"));
  await mkdir(dir, { recursive: true });
  await Bun.write(targetPath, JSON.stringify(config, null, 2) + "\n");
}

/**
 * Tool registry for cmux101.
 *
 * BuiltinToolRegistry implements the ToolRegistry interface from core/types.
 * createDefaultToolRegistry() is ASYNC — always `await` it.
 */

import { zodToJsonSchema } from "zod-to-json-schema";
import type { Tool, ToolRegistry, ToolSchema } from "../core/types.js";

// ---------------------------------------------------------------------------
// Internal helper
// ---------------------------------------------------------------------------

async function tryImport<T>(path: string): Promise<T | null> {
  try {
    return await import(path);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// BuiltinToolRegistry
// ---------------------------------------------------------------------------

/**
 * Concrete implementation of ToolRegistry that manages a flat map of tools.
 *
 * Named BuiltinToolRegistry to avoid a name clash with the ToolRegistry
 * interface exported from core/types.
 */
export class BuiltinToolRegistry implements ToolRegistry {
  private readonly tools = new Map<string, Tool>();

  /**
   * Register a tool. Throws if a tool with the same name is already registered.
   */
  register(tool: Tool): void {
    if (this.tools.has(tool.name)) {
      throw new Error(
        `BuiltinToolRegistry: tool "${tool.name}" is already registered`,
      );
    }
    this.tools.set(tool.name, tool);
  }

  /**
   * Unregister a tool by name. Returns true if it was registered, false if not.
   */
  unregister(name: string): boolean {
    return this.tools.delete(name);
  }

  /** Look up a tool by name. */
  get(name: string): Tool | undefined {
    return this.tools.get(name);
  }

  /** List all registered tools. */
  list(): Tool[] {
    return Array.from(this.tools.values());
  }

  /**
   * Convert registered tools to ToolSchema[] for passing to a provider.
   *
   * Converts each tool's Zod schema to JSON Schema via zod-to-json-schema.
   * Strips `$schema` and `additionalProperties` from the generated schema
   * because some providers reject those fields.
   *
   * @param filter Optional predicate; only matching tools are included.
   */
  toSchemas(filter?: (t: Tool) => boolean): ToolSchema[] {
    const schemas: ToolSchema[] = [];
    for (const tool of this.tools.values()) {
      if (filter && !filter(tool)) continue;

      const raw = zodToJsonSchema(tool.inputSchema, {
        $refStrategy: "none",
      }) as Record<string, unknown>;

      // Strip fields some providers reject
      delete raw["$schema"];
      delete raw["additionalProperties"];

      schemas.push({
        name: tool.name,
        description: tool.description,
        inputSchema: raw,
      });
    }
    return schemas;
  }
}

// ---------------------------------------------------------------------------
// createDefaultToolRegistry — ASYNC
// ---------------------------------------------------------------------------

/**
 * Create a BuiltinToolRegistry pre-populated with all built-in tools.
 *
 * Uses dynamic imports so missing tool modules don't crash registration.
 * Subagent and MCP tools are NOT registered here — the runner adds those once
 * it has a dispatcher.
 *
 * @param opts.includeCmux Whether to register cmux-specific tool pack.
 *   Defaults to probing cmux/index.ts's cmuxAvailable() if present, otherwise
 *   false.
 *
 * @example
 *   const tools = await createDefaultToolRegistry();
 */
export async function createDefaultToolRegistry(opts?: {
  includeCmux?: boolean;
}): Promise<BuiltinToolRegistry> {
  const registry = new BuiltinToolRegistry();

  type ToolModule = Record<string, unknown>;

  const builtinPaths = [
    "./file_read.js",
    "./file_write.js",
    "./file_edit.js",
    "./shell.js",
    "./glob.js",
    "./grep.js",
    "./web_fetch.js",
    "./web_search.js",
  ];

  const imports = await Promise.all(
    builtinPaths.map((p) => tryImport<ToolModule>(p)),
  );

  for (const mod of imports) {
    if (!mod) continue;
    for (const value of Object.values(mod)) {
      if (
        value !== null &&
        typeof value === "object" &&
        "name" in value &&
        "description" in value &&
        "inputSchema" in value &&
        "run" in value
      ) {
        try {
          registry.register(value as Tool);
        } catch {
          // Duplicate names are silently skipped during bulk registration
        }
      }
    }
  }

  // Determine whether to include cmux tools
  let includeCmux = opts?.includeCmux;
  if (includeCmux === undefined) {
    const cmuxIndex = await tryImport<{ cmuxAvailable?: () => Promise<boolean> }>(
      "./cmux/index.js",
    );
    if (cmuxIndex && typeof cmuxIndex.cmuxAvailable === "function") {
      try {
        includeCmux = await cmuxIndex.cmuxAvailable();
      } catch {
        includeCmux = false;
      }
    } else {
      includeCmux = false;
    }
  }

  if (includeCmux) {
    const cmuxPaths = [
      "./cmux/panes.js",
      "./cmux/workspaces.js",
      "./cmux/tree.js",
      "./cmux/io.js",
      "./cmux/notify.js",
    ];
    const cmuxImports = await Promise.all(
      cmuxPaths.map((p) => tryImport<ToolModule>(p)),
    );
    for (const mod of cmuxImports) {
      if (!mod) continue;
      for (const value of Object.values(mod)) {
        if (
          value !== null &&
          typeof value === "object" &&
          "name" in value &&
          "description" in value &&
          "inputSchema" in value &&
          "run" in value
        ) {
          try {
            registry.register(value as Tool);
          } catch {
            // Skip duplicates
          }
        }
      }
    }
  }

  return registry;
}

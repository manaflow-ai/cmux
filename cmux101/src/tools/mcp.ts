/**
 * MCP tool adapters — turns McpConnection tool definitions into cmux101 Tools.
 */

import { z } from "zod";
import type { ZodTypeAny } from "zod";
import type { Tool, ToolContext, ToolResult, Config } from "../core/types.js";
import { McpClientManager, type McpConnection } from "../mcp/client.js";

// ----------------------------------------------------------------------------
// JSON Schema → Zod conversion
// ----------------------------------------------------------------------------

type JsonSchema = Record<string, unknown>;

export function jsonSchemaToZod(schema: JsonSchema): ZodTypeAny {
  try {
    return _jsonSchemaToZod(schema);
  } catch {
    return z.record(z.unknown());
  }
}

function _jsonSchemaToZod(schema: JsonSchema): ZodTypeAny {
  if (!schema || typeof schema !== "object") {
    return z.unknown();
  }

  // Handle enum first (can appear on any type)
  if (Array.isArray(schema.enum)) {
    const values = schema.enum as [unknown, ...unknown[]];
    if (values.length === 0) return z.never();
    // Zod enum requires string values; for mixed types use z.union of literals
    if (values.every((v) => typeof v === "string")) {
      return z.enum(values as [string, ...string[]]);
    }
    const [first, ...rest] = values;
    if (rest.length === 0) return z.literal(first as string | number | boolean);
    const unionMembers = [
      z.literal(first as string | number | boolean),
      ...rest.map((v) => z.literal(v as string | number | boolean)),
    ] as unknown as [ZodTypeAny, ZodTypeAny, ...ZodTypeAny[]];
    return z.union(unionMembers);
  }

  const type = schema.type as string | string[] | undefined;

  if (Array.isArray(type)) {
    // e.g. type: ["string", "null"] — fall back
    return z.record(z.unknown());
  }

  switch (type) {
    case "string":
      return z.string();

    case "number":
      return z.number();

    case "integer":
      return z.number().int();

    case "boolean":
      return z.boolean();

    case "null":
      return z.null();

    case "array": {
      const items = schema.items as JsonSchema | undefined;
      if (items) {
        return z.array(_jsonSchemaToZod(items));
      }
      return z.array(z.unknown());
    }

    case "object": {
      const properties = schema.properties as
        | Record<string, JsonSchema>
        | undefined;
      const required = (schema.required as string[]) ?? [];

      if (!properties) {
        return z.record(z.unknown());
      }

      const shape: Record<string, ZodTypeAny> = {};
      for (const [key, propSchema] of Object.entries(properties)) {
        let fieldSchema = _jsonSchemaToZod(propSchema);
        if (!required.includes(key)) {
          fieldSchema = fieldSchema.optional();
        }
        shape[key] = fieldSchema;
      }

      return z.object(shape);
    }

    default:
      // No type or unrecognized — fallback
      return z.record(z.unknown());
  }
}

// ----------------------------------------------------------------------------
// Name sanitization
// ----------------------------------------------------------------------------

function sanitizeName(name: string): string {
  return name.replace(/[/\s]+/g, "_").toLowerCase();
}

// ----------------------------------------------------------------------------
// buildMcpTools
// ----------------------------------------------------------------------------

export function buildMcpTools(connections: McpConnection[]): Tool[] {
  const tools: Tool[] = [];

  for (const connection of connections) {
    for (const toolInfo of connection.tools) {
      const safeName = `mcp__${sanitizeName(connection.name)}__${sanitizeName(toolInfo.name)}`;
      const description = `[MCP/${connection.name}] ${toolInfo.description ?? ""}`.trim();

      let inputSchema: ZodTypeAny;
      try {
        inputSchema = jsonSchemaToZod(
          toolInfo.inputSchema as Record<string, unknown>,
        );
      } catch {
        inputSchema = z.record(z.unknown());
      }

      const toolName = toolInfo.name;
      const conn = connection;

      const tool: Tool = {
        name: safeName,
        description,
        inputSchema,
        defaultPermission: "ask",
        async run(
          input: unknown,
          ctx: ToolContext,
        ): Promise<ToolResult<unknown>> {
          try {
            // Honor abortSignal if possible via a race
            const callPromise = conn.callTool(
              toolName,
              input as Record<string, unknown>,
            );

            let result: unknown;
            if (ctx.abortSignal.aborted) {
              return {
                content: "MCP tool call aborted.",
                isError: true,
              };
            }

            // Race the tool call against an abort promise
            result = await new Promise<unknown>((resolve, reject) => {
              const onAbort = () => reject(new Error("MCP tool call aborted."));
              ctx.abortSignal.addEventListener("abort", onAbort, {
                once: true,
              });
              callPromise.then(
                (v) => {
                  ctx.abortSignal.removeEventListener("abort", onAbort);
                  resolve(v);
                },
                (e) => {
                  ctx.abortSignal.removeEventListener("abort", onAbort);
                  reject(e);
                },
              );
            });

            // Map MCP response to ToolResult
            const content = mapMcpResultToContent(result);
            return { content };
          } catch (err) {
            const message =
              err instanceof Error ? err.message : String(err);
            return { content: message, isError: true };
          }
        },
      };

      tools.push(tool);
    }
  }

  return tools;
}

// ----------------------------------------------------------------------------
// Map MCP content array to a string
// ----------------------------------------------------------------------------

function mapMcpResultToContent(result: unknown): string {
  if (result === null || result === undefined) return "";
  if (typeof result === "string") return result;

  if (typeof result === "object") {
    const r = result as Record<string, unknown>;
    if (Array.isArray(r.content)) {
      const parts: string[] = [];
      for (const block of r.content) {
        if (
          block &&
          typeof block === "object" &&
          (block as Record<string, unknown>).type === "text"
        ) {
          parts.push(String((block as Record<string, unknown>).text ?? ""));
        } else {
          parts.push(JSON.stringify(block));
        }
      }
      return parts.join("\n");
    }
  }

  return JSON.stringify(result);
}

// ----------------------------------------------------------------------------
// loadMcpFromConfig
// ----------------------------------------------------------------------------

type LogFn = (level: "debug" | "info" | "warn" | "error", msg: string) => void;

export async function loadMcpFromConfig(
  config: Config,
  log: LogFn,
): Promise<{ connections: McpConnection[]; tools: Tool[] }> {
  const manager = new McpClientManager(log);
  const serverConfigs = config.mcp ?? [];

  const settled = await Promise.allSettled(
    serverConfigs.map((sc) => manager.connect(sc)),
  );

  const connections: McpConnection[] = [];
  for (let i = 0; i < settled.length; i++) {
    const result = settled[i];
    if (result.status === "fulfilled") {
      connections.push(result.value);
    } else {
      log(
        "error",
        `[MCP] Failed to connect to "${serverConfigs[i].name}": ${result.reason}`,
      );
    }
  }

  const tools = buildMcpTools(connections);
  return { connections, tools };
}

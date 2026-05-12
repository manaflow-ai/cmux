import { z } from "zod";
import type { Tool, ToolContext, ToolResult } from "../core/types.js";

// ----------------------------------------------------------------------------
// Tiny JSON-schema subset validator
// Supports type:"object" with properties that are string/number/boolean.
// ----------------------------------------------------------------------------

function validateAgainstSchema(
  schema: Record<string, unknown>,
  data: Record<string, unknown>,
): string | null {
  if (schema["type"] !== "object") {
    return 'Schema must have type:"object"';
  }

  const properties = schema["properties"] as Record<string, { type: string }> | undefined;
  const required = schema["required"] as string[] | undefined;

  if (required) {
    for (const key of required) {
      if (!(key in data)) {
        return `Missing required field: "${key}"`;
      }
    }
  }

  if (properties) {
    for (const [key, propSchema] of Object.entries(properties)) {
      if (!(key in data)) continue; // not present and not required — skip

      const value = data[key];
      const expectedType = propSchema.type;

      if (expectedType === "string" && typeof value !== "string") {
        return `Field "${key}" must be a string, got ${typeof value}`;
      }
      if (expectedType === "number" && typeof value !== "number") {
        return `Field "${key}" must be a number, got ${typeof value}`;
      }
      if (expectedType === "boolean" && typeof value !== "boolean") {
        return `Field "${key}" must be a boolean, got ${typeof value}`;
      }
    }
  }

  return null; // valid
}

// ----------------------------------------------------------------------------
// structured_output
// ----------------------------------------------------------------------------

export const structuredOutputTool: Tool = {
  name: "structured_output",
  description:
    "Declare a structured JSON response. Validates data against a simple JSON-schema subset " +
    "(type:object with string/number/boolean properties) and returns it formatted.",
  inputSchema: z.object({
    schema: z.record(z.unknown()),
    data: z.record(z.unknown()),
  }),
  defaultPermission: "allow",

  async run(input: unknown, _ctx: ToolContext): Promise<ToolResult> {
    const parsed = (
      structuredOutputTool.inputSchema as ReturnType<typeof z.object>
    ).parse(input) as {
      schema: Record<string, unknown>;
      data: Record<string, unknown>;
    };

    const error = validateAgainstSchema(parsed.schema, parsed.data);
    if (error) {
      return { content: `Schema validation error: ${error}`, isError: true };
    }

    return { content: JSON.stringify(parsed.data, null, 2) };
  },
};

export const structuredOutputTools: Tool[] = [structuredOutputTool];

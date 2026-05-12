/**
 * Unit tests for BuiltinToolRegistry and createDefaultToolRegistry.
 */

import { test, expect, describe } from "bun:test";
import { z } from "zod";
import { BuiltinToolRegistry, createDefaultToolRegistry } from "../../../src/tools/index.js";
import type { Tool, ToolContext, ToolResult } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// Fake fixtures
// ---------------------------------------------------------------------------

function makeFakeTool(name: string, description = "A test tool"): Tool {
  return {
    name,
    description,
    inputSchema: z.object({
      message: z.string().describe("A message"),
      count: z.number().int().optional().describe("Optional count"),
    }),
    async run(_input: unknown, _ctx: ToolContext): Promise<ToolResult> {
      return { content: "ok" };
    },
  };
}

// ---------------------------------------------------------------------------
// BuiltinToolRegistry
// ---------------------------------------------------------------------------

describe("BuiltinToolRegistry", () => {
  test("register and get a tool", () => {
    const registry = new BuiltinToolRegistry();
    const tool = makeFakeTool("my_tool");
    registry.register(tool);

    const found = registry.get("my_tool");
    expect(found).toBeDefined();
    expect(found!.name).toBe("my_tool");
  });

  test("list returns all registered tools", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("tool_a"));
    registry.register(makeFakeTool("tool_b"));
    registry.register(makeFakeTool("tool_c"));

    const names = registry.list().map((t) => t.name).sort();
    expect(names).toEqual(["tool_a", "tool_b", "tool_c"]);
  });

  test("get returns undefined for unknown tool", () => {
    const registry = new BuiltinToolRegistry();
    expect(registry.get("nonexistent")).toBeUndefined();
  });

  test("duplicate name throws", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("dup_tool"));

    expect(() => registry.register(makeFakeTool("dup_tool"))).toThrow(
      /dup_tool.*already registered/,
    );
  });

  test("unregister removes a tool and returns true", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("removable"));

    const result = registry.unregister("removable");

    expect(result).toBe(true);
    expect(registry.get("removable")).toBeUndefined();
    expect(registry.list()).toHaveLength(0);
  });

  test("unregister returns false for unknown tool", () => {
    const registry = new BuiltinToolRegistry();
    expect(registry.unregister("ghost")).toBe(false);
  });

  test("unregister allows re-registration with same name", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("reusable"));
    registry.unregister("reusable");
    // Should not throw
    registry.register(makeFakeTool("reusable", "New description"));
    expect(registry.get("reusable")!.description).toBe("New description");
  });
});

// ---------------------------------------------------------------------------
// toSchemas
// ---------------------------------------------------------------------------

describe("BuiltinToolRegistry.toSchemas", () => {
  test("returns correct shape for registered tools", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("schema_tool", "Test the schema shape"));

    const schemas = registry.toSchemas();

    expect(schemas).toHaveLength(1);
    const [schema] = schemas;
    expect(schema.name).toBe("schema_tool");
    expect(schema.description).toBe("Test the schema shape");
    expect(schema.inputSchema).toBeDefined();
    expect(typeof schema.inputSchema).toBe("object");
  });

  test("strips $schema from JSON Schema output", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("no_dollar_schema"));

    const schemas = registry.toSchemas();
    expect("$schema" in schemas[0].inputSchema).toBe(false);
  });

  test("strips additionalProperties from JSON Schema output", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("no_additional_props"));

    const schemas = registry.toSchemas();
    expect("additionalProperties" in schemas[0].inputSchema).toBe(false);
  });

  test("inputSchema contains expected properties", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("props_tool"));

    const schemas = registry.toSchemas();
    const inputSchema = schemas[0].inputSchema as { properties?: Record<string, unknown>; type?: string };

    expect(inputSchema.type).toBe("object");
    expect(inputSchema.properties).toBeDefined();
    expect("message" in inputSchema.properties!).toBe(true);
    expect("count" in inputSchema.properties!).toBe(true);
  });

  test("filter limits which tools appear in schemas", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("alpha_tool"));
    registry.register(makeFakeTool("beta_tool"));
    registry.register(makeFakeTool("gamma_tool"));

    const schemas = registry.toSchemas((t) => t.name.startsWith("alpha"));

    expect(schemas).toHaveLength(1);
    expect(schemas[0].name).toBe("alpha_tool");
  });

  test("returns empty array when no tools registered", () => {
    const registry = new BuiltinToolRegistry();
    expect(registry.toSchemas()).toEqual([]);
  });

  test("filter returning false for all tools yields empty array", () => {
    const registry = new BuiltinToolRegistry();
    registry.register(makeFakeTool("hidden_tool"));

    const schemas = registry.toSchemas(() => false);
    expect(schemas).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// createDefaultToolRegistry
// ---------------------------------------------------------------------------

describe("createDefaultToolRegistry", () => {
  test("returns a BuiltinToolRegistry instance", async () => {
    const registry = await createDefaultToolRegistry({ includeCmux: false });
    expect(registry).toBeInstanceOf(BuiltinToolRegistry);
  });

  test("does not crash without env or config", async () => {
    const registry = await createDefaultToolRegistry({ includeCmux: false });
    expect(registry).toBeDefined();
  });

  test("registers built-in tools when modules are present", async () => {
    const registry = await createDefaultToolRegistry({ includeCmux: false });
    const names = registry.list().map((t) => t.name);
    // At least some built-in tools should be registered
    // (all tool files exist in this project)
    expect(names.length).toBeGreaterThan(0);
    // Spot-check known tools
    expect(names).toContain("file_read");
    expect(names).toContain("file_write");
    expect(names).toContain("shell");
  });

  test("toSchemas works on the default registry", async () => {
    const registry = await createDefaultToolRegistry({ includeCmux: false });
    const schemas = registry.toSchemas();
    expect(schemas.length).toBeGreaterThan(0);
    for (const s of schemas) {
      expect(typeof s.name).toBe("string");
      expect(typeof s.description).toBe("string");
      expect(typeof s.inputSchema).toBe("object");
      expect("$schema" in s.inputSchema).toBe(false);
      expect("additionalProperties" in s.inputSchema).toBe(false);
    }
  });
});

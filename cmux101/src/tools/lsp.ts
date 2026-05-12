/**
 * lsp tool — stub for LSP (Language Server Protocol) integration.
 *
 * This is a forward-compatibility stub. The schema is real so agents can learn
 * it and call it without crashing. Actual LSP client wiring is out of scope for
 * this iteration; configure an MCP language-server instead.
 */

import { z } from "zod";
import type { Tool, ToolContext, ToolResult } from "../core/types";

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

const inputSchema = z.object({
  action: z.enum(["hover", "definition", "references", "diagnostics", "symbols", "format"]),
  path: z.string(),
  line: z.number().int().nonnegative().optional(),
  character: z.number().int().nonnegative().optional(),
  query: z.string().optional(),
});

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

export const lspTool: Tool = {
  name: "lsp",
  description:
    "Query a Language Server Protocol (LSP) server: hover info, go-to-definition, references, diagnostics, symbols, or format a file. (Stub — LSP not yet wired; configure a language-server via mcp_<server> for now.)",
  inputSchema,
  defaultPermission: "allow",

  async run(_input: unknown, _ctx: ToolContext): Promise<ToolResult> {
    return {
      content:
        "LSP integration not yet implemented — install a language server and configure mcp_<server> for now, or use grep/file_read.",
      isError: false,
    };
  },
};

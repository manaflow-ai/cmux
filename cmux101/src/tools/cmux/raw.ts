/**
 * raw.ts — escape-hatch tool to run any cmux command directly.
 *
 * cmux_raw passes args straight to `cmux <args...>`. Use for subcommands
 * not covered by the typed tool pack. Requires user confirmation ("ask").
 */

import { z } from "zod";
import type { Tool, ToolResult } from "../../core/types";
import { runCmux } from "./exec";

const rawSchema = z.object({
  args: z
    .array(z.string())
    .min(1)
    .describe(
      "Arguments to pass to cmux, e.g. [\"browser\", \"eval\", \"document.title\"]. " +
      "Do NOT include the leading 'cmux'.",
    ),
  timeout_ms: z
    .number()
    .int()
    .positive()
    .max(120_000)
    .optional()
    .describe("Timeout in milliseconds (default: 30000, max: 120000)"),
});

export const rawTool: Tool = {
  name: "cmux_raw",
  description:
    "Escape-hatch: run any cmux subcommand directly by passing raw args. Use when no typed cmux tool covers the command you need. Requires user approval before execution.",
  inputSchema: rawSchema,
  defaultPermission: "ask",

  async run(input: unknown): Promise<ToolResult> {
    const { args, timeout_ms } = rawSchema.parse(input);
    const { stdout, stderr, exitCode } = await runCmux(args, {
      timeoutMs: timeout_ms,
    });

    const output = [
      `$ cmux ${args.join(" ")}`,
      stdout ? `stdout:\n${stdout}` : null,
      stderr ? `stderr:\n${stderr}` : null,
      `exit: ${exitCode}`,
    ]
      .filter(Boolean)
      .join("\n");

    return {
      content: output,
      isError: exitCode !== 0,
    };
  },
};

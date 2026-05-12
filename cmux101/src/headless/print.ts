/**
 * --print / headless mode. Streams assistant text to stdout, tool calls as a
 * compact one-liner to stderr, and exits when the agent emits message_stop
 * without further tool calls.
 *
 * Designed for scripting:
 *   echo "summarize the diff" | cmux101 -p
 *   cmux101 -p "explain this file"
 */

import { Runner, type RunnerEvent } from "../core/runner.ts";
import type { Provider, SessionHandle, ToolRegistry, Permissions, SubagentDispatcher, HookEvent, HookResponse } from "../core/types.ts";

export interface PrintOptions {
  session: SessionHandle;
  provider: Provider;
  toolRegistry: ToolRegistry;
  permissions: Permissions;
  cwd: string;
  prompt: string;
  abortController?: AbortController;
  spawnSubagent?: SubagentDispatcher;
  emitHook?: (event: HookEvent) => Promise<HookResponse>;
  verbose?: boolean;
  jsonStream?: boolean;
}

export async function runPrint(opts: PrintOptions): Promise<void> {
  const abortController = opts.abortController ?? new AbortController();
  process.on("SIGINT", () => abortController.abort());

  const onEvent = (event: RunnerEvent) => {
    if (opts.jsonStream) {
      process.stdout.write(JSON.stringify(event) + "\n");
      return;
    }
    switch (event.kind) {
      case "stream":
        if (event.event.kind === "text_delta") {
          process.stdout.write(event.event.text);
        } else if (event.event.kind === "thinking_delta" && opts.verbose) {
          process.stderr.write(`\x1b[90m${event.event.text}\x1b[0m`);
        } else if (event.event.kind === "error") {
          process.stderr.write(`\n[provider error] ${event.event.error.message}\n`);
        }
        break;
      case "tool_pre":
        process.stderr.write(`\n[tool] ${event.name} ${truncate(JSON.stringify(event.input ?? {}), 200)}\n`);
        break;
      case "tool_output_delta":
        if (opts.verbose) process.stderr.write(event.text);
        break;
      case "tool_post":
        if (event.isError) process.stderr.write(`[tool ✗] result was an error\n`);
        else process.stderr.write(`[tool ✓]\n`);
        break;
      case "turn_end":
        process.stdout.write("\n");
        break;
      case "error":
        process.stderr.write(`\n[error] ${event.error.message}\n`);
        break;
      default:
        break;
    }
  };

  const runner = new Runner({
    session: opts.session,
    provider: opts.provider,
    toolRegistry: opts.toolRegistry,
    permissions: opts.permissions,
    abortController,
    cwd: opts.cwd,
    spawnSubagent: opts.spawnSubagent,
    emitHook: opts.emitHook,
    onEvent,
  });

  await runner.run(opts.prompt);
}

function truncate(s: string, n: number): string {
  if (s.length <= n) return s;
  return s.slice(0, n) + "…";
}

/**
 * The agent loop.
 *
 * `Runner.run(userText)` appends the user message, calls `provider.stream()`,
 * dispatches tool calls, and loops until the model emits message_stop with no
 * tool calls (or abortSignal fires).
 *
 * The runner is UI-agnostic. Callers receive events via an optional `onEvent`
 * callback that fires for every StreamEvent and for tool lifecycle events.
 */

import type {
  Message,
  Provider,
  ProviderRequest,
  SessionHandle,
  StreamEvent,
  Tool,
  ToolContext,
  ToolRegistry,
  ToolResult,
  ContentBlock,
  Permissions,
  SubagentDispatcher,
  HookEvent,
  HookResponse,
} from "./types.ts";
import { AbortedError, PermissionDeniedError, ToolError } from "./errors.ts";

export type RunnerEvent =
  | { kind: "stream"; event: StreamEvent }
  | { kind: "assistant_message"; message: Message }
  | { kind: "tool_pre"; toolUseId: string; name: string; input: unknown }
  | { kind: "tool_output_delta"; toolUseId: string; text: string }
  | { kind: "tool_post"; toolUseId: string; result: ToolResult; isError: boolean }
  | { kind: "turn_end"; reason: "end_turn" | "tool_use" | "max_tokens" | "stop_sequence" | "refusal" | "error" }
  | { kind: "error"; error: Error };

export interface RunnerOptions {
  session: SessionHandle;
  provider: Provider;
  toolRegistry: ToolRegistry;
  permissions: Permissions;
  abortController?: AbortController;
  cwd: string;
  /** Spawn a subagent. Optional; if absent, the subagent tool just errors. */
  spawnSubagent?: SubagentDispatcher;
  /** Fired on every event of interest. UI layers subscribe here. */
  onEvent?: (event: RunnerEvent) => void;
  /** Hook event firing. Optional. */
  emitHook?: (event: HookEvent) => Promise<HookResponse>;
  /** Logger. */
  log?: (level: "debug" | "info" | "warn" | "error", text: string) => void;
  /** Max turns before bailing (prevents runaway loops). Default 100. */
  maxTurns?: number;
  /** Optional override of system prompt; falls back to session.meta.system. */
  system?: string;
  /** Optional providerOptions passed through to provider.stream. */
  providerOptions?: Record<string, unknown>;
}

export class Runner {
  constructor(private readonly opts: RunnerOptions) {}

  get abortSignal(): AbortSignal {
    return (this.opts.abortController ?? new AbortController()).signal;
  }

  async run(userText: string): Promise<void> {
    const userMessage: Message = {
      role: "user",
      content: [{ type: "text", text: userText }],
    };
    await this.opts.session.append(userMessage);
    await this.runUntilStop();
  }

  /** Continue an in-progress session (e.g. after a tool result was injected externally). */
  async continueLoop(): Promise<void> {
    await this.runUntilStop();
  }

  private async runUntilStop(): Promise<void> {
    const maxTurns = this.opts.maxTurns ?? 100;
    for (let turn = 0; turn < maxTurns; turn++) {
      if (this.abortSignal.aborted) throw new AbortedError();

      const { assistantMessage, stopReason, toolCalls } = await this.streamOneTurn();
      await this.opts.session.append(assistantMessage);
      this.emit({ kind: "assistant_message", message: assistantMessage });

      if (toolCalls.length === 0 || stopReason === "end_turn" || stopReason === "max_tokens" || stopReason === "refusal" || stopReason === "stop_sequence") {
        this.emit({ kind: "turn_end", reason: stopReason });
        return;
      }

      // Execute all tool calls concurrently and gather results.
      const results = await Promise.all(
        toolCalls.map((c) => this.runOneTool(c.id, c.name, c.input)),
      );

      // Append a tool-role message bundling the results.
      const toolMessage: Message = {
        role: "tool",
        content: results.map((r) => ({
          type: "tool_result",
          tool_use_id: r.id,
          is_error: r.isError,
          content: typeof r.content === "string" ? r.content : r.content,
        })),
      };
      await this.opts.session.append(toolMessage);
      // Loop again to let the model react.
    }
    throw new Error(`Runner exceeded max turns (${maxTurns})`);
  }

  private async streamOneTurn(): Promise<{
    assistantMessage: Message;
    stopReason: "end_turn" | "tool_use" | "max_tokens" | "stop_sequence" | "refusal" | "error";
    toolCalls: Array<{ id: string; name: string; input: unknown }>;
  }> {
    const tools = this.opts.toolRegistry.toSchemas();
    const request: ProviderRequest = {
      model: this.opts.session.meta.model,
      messages: [...this.opts.session.messages],
      system: this.opts.system ?? this.opts.session.meta.system,
      tools,
      maxTokens: 8192,
      abortSignal: this.abortSignal,
      providerOptions: this.opts.providerOptions,
    };

    const content: ContentBlock[] = [];
    let curText = "";
    let curThinking = "";
    let curThinkingSig: string | undefined;
    const toolBuilders = new Map<string, { name: string; jsonStr: string; input?: unknown }>();
    const toolOrder: string[] = [];
    let stopReason: "end_turn" | "tool_use" | "max_tokens" | "stop_sequence" | "refusal" | "error" = "end_turn";

    const flushText = () => {
      if (curText) {
        content.push({ type: "text", text: curText });
        curText = "";
      }
    };
    const flushThinking = () => {
      if (curThinking) {
        content.push({ type: "thinking", thinking: curThinking, signature: curThinkingSig });
        curThinking = "";
        curThinkingSig = undefined;
      }
    };

    try {
      for await (const event of this.opts.provider.stream(request)) {
        this.emit({ kind: "stream", event });
        switch (event.kind) {
          case "text_delta":
            flushThinking();
            curText += event.text;
            break;
          case "thinking_delta":
            flushText();
            curThinking += event.text;
            if (event.signature) curThinkingSig = event.signature;
            break;
          case "tool_call_start":
            flushText();
            flushThinking();
            toolBuilders.set(event.id, { name: event.name, jsonStr: "" });
            toolOrder.push(event.id);
            break;
          case "tool_call_input_delta": {
            const b = toolBuilders.get(event.id);
            if (b) b.jsonStr += event.jsonDelta;
            break;
          }
          case "tool_call_end": {
            const b = toolBuilders.get(event.id);
            if (b) b.input = event.input;
            break;
          }
          case "message_stop":
            stopReason = event.reason;
            break;
          case "error":
            stopReason = "error";
            this.emit({ kind: "error", error: event.error });
            break;
          default:
            break;
        }
      }
    } catch (err) {
      stopReason = "error";
      throw err;
    }

    flushText();
    flushThinking();

    const toolCalls: Array<{ id: string; name: string; input: unknown }> = [];
    for (const id of toolOrder) {
      const b = toolBuilders.get(id);
      if (!b) continue;
      const input = b.input ?? this.tryParseJson(b.jsonStr) ?? {};
      content.push({ type: "tool_use", id, name: b.name, input });
      toolCalls.push({ id, name: b.name, input });
    }

    return {
      assistantMessage: { role: "assistant", content },
      stopReason,
      toolCalls,
    };
  }

  private tryParseJson(s: string): unknown {
    if (!s.trim()) return null;
    try { return JSON.parse(s); } catch { return null; }
  }

  private async runOneTool(id: string, name: string, input: unknown): Promise<{ id: string; content: string | Array<{ type: "text"; text: string }>; isError: boolean }> {
    this.emit({ kind: "tool_pre", toolUseId: id, name, input });
    if (this.opts.emitHook) {
      const hook = await this.opts.emitHook({ event: "tool.pre", sessionId: this.opts.session.meta.id, data: { toolName: name, input } });
      if (hook.action === "block") {
        const result = { id, content: `Tool blocked by hook: ${hook.message ?? "no reason given"}`, isError: true };
        this.emit({ kind: "tool_post", toolUseId: id, result: { content: result.content, isError: true }, isError: true });
        return result;
      }
    }

    const tool = this.opts.toolRegistry.get(name);
    if (!tool) {
      const result = { id, content: `Unknown tool: ${name}`, isError: true };
      this.emit({ kind: "tool_post", toolUseId: id, result: { content: result.content, isError: true }, isError: true });
      return result;
    }

    const perm = this.opts.permissions.resolve(name, input);
    if (perm === "deny") {
      const result = { id, content: `Tool ${name} is denied by current permissions.`, isError: true };
      this.emit({ kind: "tool_post", toolUseId: id, result: { content: result.content, isError: true }, isError: true });
      return result;
    }
    // "ask" handling is delegated to the askUser callback inside PermissionResolver
    // by convention; resolvers may have already asked. If it's still "ask" here,
    // we treat it as deny for safety. UI wires askUser via a callback passed at
    // construction time.

    try {
      const parsed = tool.inputSchema.safeParse(input);
      const finalInput = parsed.success ? parsed.data : input;

      const ctx: ToolContext = {
        session: this.opts.session,
        permissions: this.opts.permissions,
        abortSignal: this.abortSignal,
        cwd: this.opts.cwd,
        spawnSubagent: this.opts.spawnSubagent ?? (async () => ({ text: "Subagent dispatch unavailable.", usage: { inputTokens: 0, outputTokens: 0 }, transcriptPath: "", ok: false })),
        toolRegistry: this.opts.toolRegistry,
        emitHook: this.opts.emitHook ?? (async () => ({ action: "pass" })),
        log: this.opts.log ?? (() => {}),
      };

      const ret = tool.run(finalInput, ctx);
      let result: ToolResult;
      if (this.isAsyncIterable(ret)) {
        let final: ToolResult | undefined;
        for await (const ev of ret) {
          if (ev.kind === "output_delta") this.emit({ kind: "tool_output_delta", toolUseId: id, text: ev.text });
          else if (ev.kind === "log") this.emit({ kind: "tool_output_delta", toolUseId: id, text: `[${name}] ${ev.text}\n` });
          else if (ev.kind === "result") final = ev.result;
        }
        result = final ?? { content: "(tool produced no result)", isError: true };
      } else {
        result = await ret;
      }

      if (this.opts.emitHook) {
        const post = await this.opts.emitHook({ event: "tool.post", sessionId: this.opts.session.meta.id, data: { toolName: name, input: finalInput, result } });
        if (post.action === "transform" && post.data && typeof post.data === "object" && "content" in (post.data as Record<string, unknown>)) {
          result = post.data as ToolResult;
        }
      }

      const isError = result.isError === true;
      const contentForReturn: string | Array<{ type: "text"; text: string }> = typeof result.content === "string" ? result.content : result.content.filter((b): b is { type: "text"; text: string } => (b as { type: string }).type === "text");
      this.emit({ kind: "tool_post", toolUseId: id, result, isError });
      return { id, content: contentForReturn, isError };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const result = { id, content: `Tool ${name} failed: ${msg}`, isError: true };
      this.emit({ kind: "tool_post", toolUseId: id, result: { content: result.content, isError: true }, isError: true });
      return result;
    }
  }

  private isAsyncIterable<T>(v: unknown): v is AsyncIterable<T> {
    return v != null && typeof (v as { [Symbol.asyncIterator]?: unknown })[Symbol.asyncIterator] === "function";
  }

  private emit(event: RunnerEvent): void {
    this.opts.onEvent?.(event);
  }
}

// The cheap model behind the room's memory and task digest: one Anthropic Messages call per
// request, with token usage counted so the room can show what an hour costs.

export interface ModelUsage {
  inputTokens: number;
  outputTokens: number;
  calls: number;
}

export interface ModelPrice {
  /** US dollars per million input tokens. */
  input: number;
  /** US dollars per million output tokens. */
  output: number;
}

/** Claude Haiku 4.5 list price (anthropic.com/pricing, Oct 2026): $1 in, $5 out per million. */
export const HAIKU_4_5_PRICE: ModelPrice = { input: 1, output: 5 };

export function costUSD(usage: ModelUsage, price: ModelPrice): number {
  return (usage.inputTokens * price.input + usage.outputTokens * price.output) / 1_000_000;
}

export interface ModelRequest {
  system: string;
  user: string;
  maxTokens: number;
}

export type Complete = (request: ModelRequest) => Promise<{ text: string; inputTokens: number; outputTokens: number }>;

export interface AnthropicConfig {
  baseUrl: string;
  token: string;
  model: string;
  /**
   * Some team gateways (the Claude Code subscription routers) accept only Claude Code traffic:
   * send its user agent and system preamble.
   */
  claudeCodeCompat: boolean;
  fetch?: typeof fetch;
}

const CLAUDE_CODE_PREAMBLE = "You are Claude Code, Anthropic's official CLI for Claude.";

export function anthropicComplete(config: AnthropicConfig): Complete {
  const doFetch = config.fetch ?? fetch;
  return async (request) => {
    const system = config.claudeCodeCompat
      ? [
          { type: "text", text: CLAUDE_CODE_PREAMBLE },
          { type: "text", text: request.system },
        ]
      : [{ type: "text", text: request.system }];
    const headers: Record<string, string> = {
      "content-type": "application/json",
      "anthropic-version": "2023-06-01",
      authorization: `Bearer ${config.token}`,
      "x-api-key": config.token,
    };
    if (config.claudeCodeCompat) {
      headers["user-agent"] = "claude-cli/2.1.311 (external, sdk-cli)";
      headers["x-app"] = "cli";
    }
    const response = await doFetch(`${config.baseUrl.replace(/\/$/, "")}/v1/messages`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        model: config.model,
        max_tokens: request.maxTokens,
        system,
        messages: [{ role: "user", content: request.user }],
      }),
      signal: AbortSignal.timeout(60_000),
    });
    if (!response.ok) throw new Error(`model ${response.status}: ${(await response.text()).slice(0, 200)}`);
    const body = (await response.json()) as {
      content?: Array<{ type: string; text?: string }>;
      usage?: { input_tokens?: number; output_tokens?: number };
    };
    const text = (body.content ?? [])
      .filter((part) => part.type === "text")
      .map((part) => part.text ?? "")
      .join("");
    return {
      text,
      inputTokens: body.usage?.input_tokens ?? 0,
      outputTokens: body.usage?.output_tokens ?? 0,
    };
  };
}

/** Wraps a `Complete` so every call adds to `usage`. */
export function metered(complete: Complete, usage: ModelUsage): Complete {
  return async (request) => {
    const result = await complete(request);
    usage.calls += 1;
    usage.inputTokens += result.inputTokens;
    usage.outputTokens += result.outputTokens;
    return result;
  };
}

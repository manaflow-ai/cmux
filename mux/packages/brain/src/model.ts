// Streaming client for an OpenAI Responses-compatible endpoint (coderouter).

export interface ModelConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  reasoningEffort: "low" | "medium" | "high" | "xhigh";
  serviceTier?: "priority" | "default";
  /** Stable per mux, so the provider can reuse the prompt cache across turns. */
  promptCacheKey?: string;
}

export const DEFAULT_MODEL = {
  baseUrl: "https://coderouter.dev/v1",
  model: "gpt-6.1-sol",
  reasoningEffort: "high",
  serviceTier: "priority",
} as const satisfies Omit<ModelConfig, "apiKey">;

export type InputItem =
  | { role: "user" | "assistant" | "developer"; content: string }
  | { type: "function_call"; call_id: string; name: string; arguments: string }
  | { type: "function_call_output"; call_id: string; output: string };

export type OutputItem =
  | { type: "message"; content: { type: string; text?: string }[] }
  | { type: "function_call"; call_id: string; name: string; arguments: string }
  | { type: string; [key: string]: unknown };

export interface FunctionTool {
  type: "function";
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  strict?: boolean;
}

export interface ModelRequest {
  instructions: string;
  input: InputItem[];
  tools?: FunctionTool[];
}

export interface ModelResponse {
  output: OutputItem[];
  usage?: Record<string, unknown>;
}

/** Anything that turns a request into output items; tests pass a fake. */
export type Model = (request: ModelRequest, signal?: AbortSignal) => Promise<ModelResponse>;

export function responsesModel(config: ModelConfig, fetchImpl: typeof fetch = fetch): Model {
  return async (request, signal) => {
    const response = await fetchImpl(`${config.baseUrl.replace(/\/$/, "")}/responses`, {
      method: "POST",
      signal,
      headers: { authorization: `Bearer ${config.apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        model: config.model,
        instructions: request.instructions,
        input: request.input,
        tools: request.tools ?? [],
        reasoning: { effort: config.reasoningEffort },
        service_tier: config.serviceTier,
        prompt_cache_key: config.promptCacheKey,
        stream: true,
        store: false,
      }),
    });
    if (!response.ok || !response.body) {
      throw new Error(`model request failed: ${response.status} ${await response.text()}`);
    }
    return collect(response.body);
  };
}

/** Reads a Responses SSE stream into its completed output items. */
export async function collect(body: ReadableStream<Uint8Array>): Promise<ModelResponse> {
  const output: OutputItem[] = [];
  let usage: Record<string, unknown> | undefined;
  for await (const event of sseEvents(body)) {
    if (event.type === "response.output_item.done") output.push(event.item as OutputItem);
    else if (event.type === "response.completed") {
      usage = (event.response as { usage?: Record<string, unknown> } | undefined)?.usage;
    } else if (event.type === "response.failed" || event.type === "error") {
      throw new Error(`model stream failed: ${JSON.stringify(event).slice(0, 500)}`);
    }
  }
  return { output, usage };
}

async function* sseEvents(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<Record<string, unknown>> {
  const decoder = new TextDecoder();
  let buffer = "";
  const reader = body.getReader();
  for (;;) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value, { stream: !done });
    let boundary = buffer.indexOf("\n\n");
    while (boundary >= 0) {
      const block = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      const data = block
        .split("\n")
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.slice(5).trimStart())
        .join("\n");
      if (data && data !== "[DONE]") yield JSON.parse(data) as Record<string, unknown>;
      boundary = buffer.indexOf("\n\n");
    }
    if (done) return;
  }
}

export function outputText(output: OutputItem[]): string {
  return output
    .flatMap((item) => (item.type === "message" && Array.isArray(item.content) ? item.content : []))
    .map((part) => (typeof part.text === "string" ? part.text : ""))
    .join("")
    .trim();
}

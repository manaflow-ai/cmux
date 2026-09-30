import { outputText, type FunctionTool, type InputItem, type Model } from "./model.ts";

export interface ToolCall {
  name: string;
  arguments: string;
}

export interface TurnOptions {
  model: Model;
  instructions: string;
  input: InputItem[];
  tools?: FunctionTool[];
  /** Runs one tool call and returns its output text. Errors become output too. */
  runTool?: (call: ToolCall) => Promise<string>;
  /** Model calls allowed in one turn before giving up on tool loops. */
  maxSteps?: number;
  signal?: AbortSignal;
}

export interface TurnResult {
  text: string;
  /** Everything appended after `input`: tool calls, their outputs, and the reply. */
  transcript: InputItem[];
  steps: number;
}

/** Calls the model until it answers without tool calls. */
export async function runTurn(options: TurnOptions): Promise<TurnResult> {
  const maxSteps = options.maxSteps ?? 12;
  const transcript: InputItem[] = [];
  for (let step = 1; step <= maxSteps; step++) {
    const { output } = await options.model(
      {
        instructions: options.instructions,
        input: [...options.input, ...transcript],
        tools: options.tools,
      },
      options.signal,
    );
    const calls = output.filter(
      (item): item is { type: "function_call"; call_id: string; name: string; arguments: string } =>
        item.type === "function_call",
    );
    if (calls.length === 0) {
      const text = outputText(output);
      if (text) transcript.push({ role: "assistant", content: text });
      return { text, transcript, steps: step };
    }
    for (const call of calls) {
      transcript.push({
        type: "function_call",
        call_id: call.call_id,
        name: call.name,
        arguments: call.arguments,
      });
      let result: string;
      try {
        result = options.runTool ? await options.runTool(call) : `no tool named ${call.name}`;
      } catch (error) {
        result = `error: ${error instanceof Error ? error.message : String(error)}`;
      }
      transcript.push({ type: "function_call_output", call_id: call.call_id, output: result });
    }
  }
  throw new Error(`turn did not finish within ${maxSteps} model calls`);
}

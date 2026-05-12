/**
 * Pure reducer for processing StreamEvents into StreamingState.
 * Extracted from App for testability.
 */
import type { StreamEvent } from "../core/types.js";
import type { StreamingState } from "./messages.js";

export const initialStreamingState: StreamingState = {
  text: "",
  thinking: "",
  toolCalls: [],
  status: "streaming",
  toolStatus: undefined,
};

export function applyStreamEvent(
  state: StreamingState,
  event: StreamEvent
): StreamingState {
  switch (event.kind) {
    case "message_start":
      // Reset for a new message
      return { ...initialStreamingState };

    case "text_delta":
      return { ...state, text: state.text + event.text };

    case "thinking_delta":
      return { ...state, thinking: state.thinking + event.text };

    case "tool_call_start": {
      const existing = state.toolCalls.find((tc) => tc.id === event.id);
      if (existing) return state;
      return {
        ...state,
        status: "waiting_for_tool",
        toolCalls: [
          ...state.toolCalls,
          { id: event.id, name: event.name, inputJsonStr: "" },
        ],
      };
    }

    case "tool_call_input_delta": {
      return {
        ...state,
        toolCalls: state.toolCalls.map((tc) =>
          tc.id === event.id
            ? { ...tc, inputJsonStr: tc.inputJsonStr + event.jsonDelta }
            : tc
        ),
      };
    }

    case "tool_call_end": {
      const inputStr =
        typeof event.input === "string"
          ? event.input
          : JSON.stringify(event.input, null, 2);
      return {
        ...state,
        status: "tool_running",
        toolCalls: state.toolCalls.map((tc) =>
          tc.id === event.id ? { ...tc, inputJsonStr: inputStr } : tc
        ),
      };
    }

    case "message_stop":
      return { ...state, status: "done" };

    case "error":
      return { ...state, status: "error" };

    case "usage":
      // No visual change from usage events
      return state;

    default:
      return state;
  }
}

export function applyToolUpdate(
  state: StreamingState,
  update: {
    name: string;
    outputDelta?: string;
    status: StreamingState["status"];
  }
): StreamingState {
  const currentOutput = state.toolStatus?.output ?? "";
  return {
    ...state,
    status: update.status,
    toolStatus: {
      name: update.name,
      output: currentOutput + (update.outputDelta ?? ""),
    },
  };
}

/**
 * Unit tests for the TUI layer.
 *
 * ink-testing-library is not in package.json, so we skip full render tests and
 * instead unit-test the pure `applyStreamEvent` / `applyToolUpdate` reducers.
 */
import { describe, it, expect } from "bun:test";
import {
  applyStreamEvent,
  applyToolUpdate,
  initialStreamingState,
} from "../../../src/tui/streamReducer.js";
import type { StreamingState } from "../../../src/tui/messages.js";
import type { StreamEvent } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function applyAll(events: StreamEvent[]): StreamingState {
  return events.reduce(
    (state, ev) => applyStreamEvent(state, ev),
    initialStreamingState as StreamingState
  );
}

// ---------------------------------------------------------------------------
// message_start resets state
// ---------------------------------------------------------------------------

describe("applyStreamEvent", () => {
  it("message_start resets to initial state", () => {
    const dirty: StreamingState = {
      text: "hello",
      thinking: "some thought",
      toolCalls: [{ id: "x", name: "bash", inputJsonStr: "{}" }],
      status: "tool_running",
      toolStatus: { name: "bash", output: "output" },
    };
    const next = applyStreamEvent(dirty, { kind: "message_start", messageId: "m1" });
    expect(next.text).toBe("");
    expect(next.thinking).toBe("");
    expect(next.toolCalls).toHaveLength(0);
    expect(next.status).toBe("streaming");
  });

  // ---------------------------------------------------------------------------
  // text_delta accumulates
  // ---------------------------------------------------------------------------

  it("text_delta appends text", () => {
    const s1 = applyStreamEvent(initialStreamingState, {
      kind: "text_delta",
      text: "Hello",
    });
    const s2 = applyStreamEvent(s1, { kind: "text_delta", text: ", world" });
    expect(s2.text).toBe("Hello, world");
  });

  // ---------------------------------------------------------------------------
  // thinking_delta accumulates
  // ---------------------------------------------------------------------------

  it("thinking_delta appends thinking", () => {
    const s = applyAll([
      { kind: "thinking_delta", text: "Step 1. " },
      { kind: "thinking_delta", text: "Step 2." },
    ]);
    expect(s.thinking).toBe("Step 1. Step 2.");
  });

  // ---------------------------------------------------------------------------
  // tool call lifecycle
  // ---------------------------------------------------------------------------

  it("tool_call_start adds a new toolCall entry", () => {
    const s = applyStreamEvent(initialStreamingState, {
      kind: "tool_call_start",
      id: "tc1",
      name: "read_file",
    });
    expect(s.toolCalls).toHaveLength(1);
    expect(s.toolCalls[0]).toMatchObject({ id: "tc1", name: "read_file", inputJsonStr: "" });
    expect(s.status).toBe("waiting_for_tool");
  });

  it("tool_call_input_delta accumulates json", () => {
    const s = applyAll([
      { kind: "tool_call_start", id: "tc1", name: "bash" },
      { kind: "tool_call_input_delta", id: "tc1", jsonDelta: '{"cmd"' },
      { kind: "tool_call_input_delta", id: "tc1", jsonDelta: ':"ls"}' },
    ]);
    expect(s.toolCalls[0].inputJsonStr).toBe('{"cmd":"ls"}');
  });

  it("tool_call_end sets status to tool_running and finalizes inputJsonStr", () => {
    const s = applyAll([
      { kind: "tool_call_start", id: "tc1", name: "bash" },
      { kind: "tool_call_end", id: "tc1", input: { cmd: "ls" } },
    ]);
    expect(s.status).toBe("tool_running");
    // input should be serialized as JSON
    expect(s.toolCalls[0].inputJsonStr).toContain("ls");
  });

  it("duplicate tool_call_start is ignored", () => {
    const s = applyAll([
      { kind: "tool_call_start", id: "tc1", name: "bash" },
      { kind: "tool_call_start", id: "tc1", name: "bash" },
    ]);
    expect(s.toolCalls).toHaveLength(1);
  });

  // ---------------------------------------------------------------------------
  // message_stop
  // ---------------------------------------------------------------------------

  it("message_stop sets status to done", () => {
    const s = applyStreamEvent(initialStreamingState, {
      kind: "message_stop",
      reason: "end_turn",
    });
    expect(s.status).toBe("done");
  });

  // ---------------------------------------------------------------------------
  // error
  // ---------------------------------------------------------------------------

  it("error event sets status to error", async () => {
    const { ProviderError } = await import("../../../src/core/types.js");
    const err = new ProviderError("fail", "anthropic", 500, false);
    const s = applyStreamEvent(initialStreamingState, { kind: "error", error: err });
    expect(s.status).toBe("error");
  });

  // ---------------------------------------------------------------------------
  // usage is a no-op
  // ---------------------------------------------------------------------------

  it("usage event is a no-op for streaming state", () => {
    const s = applyStreamEvent(initialStreamingState, {
      kind: "usage",
      inputTokens: 100,
      outputTokens: 50,
    });
    expect(s).toEqual(initialStreamingState);
  });
});

// ---------------------------------------------------------------------------
// applyToolUpdate
// ---------------------------------------------------------------------------

describe("applyToolUpdate", () => {
  it("sets toolStatus name and output delta", () => {
    const s = applyToolUpdate(initialStreamingState, {
      name: "bash",
      outputDelta: "line1\n",
      status: "tool_running",
    });
    expect(s.toolStatus?.name).toBe("bash");
    expect(s.toolStatus?.output).toBe("line1\n");
    expect(s.status).toBe("tool_running");
  });

  it("accumulates output deltas", () => {
    const s1 = applyToolUpdate(initialStreamingState, {
      name: "bash",
      outputDelta: "a",
      status: "tool_running",
    });
    const s2 = applyToolUpdate(s1, {
      name: "bash",
      outputDelta: "b",
      status: "tool_running",
    });
    expect(s2.toolStatus?.output).toBe("ab");
  });

  it("update without outputDelta preserves existing output", () => {
    const s1 = applyToolUpdate(initialStreamingState, {
      name: "bash",
      outputDelta: "hello",
      status: "tool_running",
    });
    const s2 = applyToolUpdate(s1, { name: "bash", status: "done" });
    expect(s2.toolStatus?.output).toBe("hello");
    expect(s2.status).toBe("done");
  });
});

// ---------------------------------------------------------------------------
// Multi-event scenario (simulates a full streaming turn)
// ---------------------------------------------------------------------------

describe("full streaming turn", () => {
  it("produces correct final state", () => {
    const events: StreamEvent[] = [
      { kind: "message_start", messageId: "m1" },
      { kind: "thinking_delta", text: "I should list files." },
      { kind: "text_delta", text: "Sure, " },
      { kind: "text_delta", text: "let me check." },
      { kind: "tool_call_start", id: "t1", name: "bash" },
      { kind: "tool_call_input_delta", id: "t1", jsonDelta: '{"cmd":"ls"}' },
      { kind: "tool_call_end", id: "t1", input: { cmd: "ls" } },
      { kind: "usage", inputTokens: 200, outputTokens: 80 },
      { kind: "message_stop", reason: "tool_use" },
    ];

    const final = applyAll(events);
    expect(final.thinking).toBe("I should list files.");
    expect(final.text).toBe("Sure, let me check.");
    expect(final.toolCalls).toHaveLength(1);
    expect(final.toolCalls[0].name).toBe("bash");
    expect(final.status).toBe("done");
  });
});

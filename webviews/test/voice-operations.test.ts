import { describe, expect, test } from "bun:test";
import {
  PROMPT_AUDIO_OP,
  REALTIME_VOICE_OPS,
  servesOperation,
  servesRealtimeVoice,
} from "../src/agent-session/acpmux/operations";

const initialize = (operations: string[]) => ({ _meta: { acpmux: { operations } } });

describe("voice operation negotiation", () => {
  test("recognizes one-shot audio independently of realtime voice", () => {
    const value = initialize([PROMPT_AUDIO_OP]);
    expect(servesOperation(value, PROMPT_AUDIO_OP)).toBe(true);
    expect(servesRealtimeVoice(value)).toBe(false);
  });

  test("requires the complete realtime operation set", () => {
    const value = initialize(Object.values(REALTIME_VOICE_OPS));
    expect(servesRealtimeVoice(value)).toBe(true);
    expect(servesOperation(value, "acp.realtime.appendText")).toBe(false);
  });

  test("does not trust a malformed initialize result", () => {
    expect(servesRealtimeVoice(undefined)).toBe(false);
    expect(servesRealtimeVoice({ _meta: { acpmux: { operations: "acp.realtime.start" } } })).toBe(false);
  });
});

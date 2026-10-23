// Leo 2026-10-22: "but also why only 10 attachments per message? is that a model limitation or...
// idk i feel like we should have better situation handling for that". The 10 was the composer's own
// (attachments.ts MAX_ATTACHMENTS, #16583); no model API or acpmux has it. One message now takes
// what the chat's harness takes (composer/messageLimit.ts), within what one acpmux message carries;
// past that the files stay staged, Send takes the first ones, and the rest go with the next message.
import { describe, expect, test } from "bun:test";
import { MAX_ATTACHMENTS, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import {
  MAX_STAGED_ATTACHMENTS,
  MESSAGE_ATTACHMENT_BYTES,
  messageLimit,
  splitForMessage,
} from "../src/agent-session/acpmux/composer/messageLimit";

/// acpmux `rpc::MAX_MESSAGE_BYTES`: the most one JSON-RPC message (one prompt) takes.
const ACPMUX_MESSAGE_BYTES = 15 * 1024 * 1024;

const chip = (index: number, bytes = 8): ComposerAttachment => ({
  id: `chip-${index}`,
  kind: "image",
  name: `shot-${index}.png`,
  mimeType: "image/png",
  size: bytes,
  data: "A".repeat(bytes),
});

describe("one message's attachment limit comes from the chat's harness", () => {
  test("each harness takes its model API's own per-request number", () => {
    expect(messageLimit({ harness: "claude" }).count).toBe(100);
    expect(messageLimit({ harness: "claude", contextWindow: 200_000 }).count).toBe(100);
    expect(messageLimit({ harness: "claude", contextWindow: 1_000_000 }).count).toBe(600);
    expect(messageLimit({ harness: "codex" }).count).toBe(1500);
    expect(messageLimit({ harness: "gemini" }).count).toBe(3600);
    // acpmux's family names the harness when its id is a profile's own.
    expect(messageLimit({ family: "claude", harness: "claude-work" }).count).toBe(100);
    expect(messageLimit({ family: "codex", harness: "codex-fast" }).count).toBe(1500);
  });

  test("a harness the table does not know takes the lowest documented number, more than the old 10", () => {
    for (const harness of ["opencode", "pi", "aider", undefined]) {
      expect(messageLimit({ harness }).count).toBe(20);
      expect(messageLimit({ harness }).count).toBeGreaterThan(MAX_ATTACHMENTS);
    }
  });

  test("every harness's message keeps its attachments inside one acpmux message", () => {
    for (const harness of ["claude", "codex", "gemini", "opencode"]) {
      const { bytes } = messageLimit({ harness });
      expect(bytes).toBe(MESSAGE_ATTACHMENT_BYTES);
      expect(bytes).toBeLessThan(ACPMUX_MESSAGE_BYTES);
    }
  });
});

describe("splitForMessage: the first attachments that fit go now, the rest wait", () => {
  test("under the limit everything goes", () => {
    const chips = Array.from({ length: 5 }, (_, index) => chip(index));
    expect(splitForMessage(chips, { count: 20, bytes: MESSAGE_ATTACHMENT_BYTES })).toEqual({ now: chips, later: [] });
  });

  test("past the count, the first `count` go and the rest wait, in order", () => {
    const chips = Array.from({ length: 25 }, (_, index) => chip(index));
    const split = splitForMessage(chips, { count: 20, bytes: MESSAGE_ATTACHMENT_BYTES });
    expect(split.now).toEqual(chips.slice(0, 20));
    expect(split.later).toEqual(chips.slice(20));
    expect(split.over).toBe("count");
  });

  test("past the bytes, the ones that fit go; the first always goes", () => {
    const four = 4 * 1024 * 1024;
    const chips = Array.from({ length: 5 }, (_, index) => chip(index, four));
    const split = splitForMessage(chips, { count: 20, bytes: 14 * 1024 * 1024 });
    expect(split.now.map((item) => item.id)).toEqual(["chip-0", "chip-1", "chip-2"]);
    expect(split.later.map((item) => item.id)).toEqual(["chip-3", "chip-4"]);
    expect(split.over).toBe("bytes");
    const huge = splitForMessage([chip(0, 20 * 1024 * 1024), chip(1)], { count: 20, bytes: 14 * 1024 * 1024 });
    expect(huge.now.map((item) => item.id)).toEqual(["chip-0"]);
    expect(huge.later.map((item) => item.id)).toEqual(["chip-1"]);
  });

  test("the composer holds more than one message takes", () => {
    expect(MAX_STAGED_ATTACHMENTS).toBeGreaterThanOrEqual(messageLimit({ harness: "claude" }).count);
  });
});

import { describe, expect, test } from "bun:test";
import { extractConversationKey } from "../src/sessionKey";

const base = {
  endpointClass: "codex" as const,
  family: "openai" as const,
  url: new URL("https://router.example/codex/messages"),
};

describe("session extraction", () => {
  test("prefers headers and collapses uuid suffixes", async () => {
    const headers = new Headers({ "x-codex-session-id": "11111111-1111-1111-1111-111111111111:turn-2" });
    await expect(extractConversationKey({ ...base, headers })).resolves.toBe(
      "codex:11111111-1111-1111-1111-111111111111",
    );
  });

  test("uses query parameters before body", async () => {
    const url = new URL("https://router.example/anthropic/messages?thread_id=query-thread");
    await expect(
      extractConversationKey({
        endpointClass: "anthropic",
        family: "anthropic",
        headers: new Headers(),
        url,
        parsedJson: { thread_id: "body-thread" },
      }),
    ).resolves.toBe("anthropic:query-thread");
  });

  test("recurses body and extracts metadata session ids", async () => {
    await expect(
      extractConversationKey({
        endpointClass: "anthropic",
        family: "anthropic",
        headers: new Headers(),
        url: new URL("https://router.example/anthropic/messages"),
        parsedJson: { metadata: { user_id: "user_session_22222222-2222-2222-2222-222222222222" } },
      }),
    ).resolves.toBe("anthropic:22222222-2222-2222-2222-222222222222");

    await expect(
      extractConversationKey({
        ...base,
        headers: new Headers(),
        parsedJson: { nested: [{ deep: { conversation_id: "deep-id" } }] },
      }),
    ).resolves.toBe("codex:deep-id");
  });

  test("falls back to a stable hashed key", async () => {
    const input = { ...base, headers: new Headers({ "user-agent": "ua" }), ip: "127.0.0.1" };
    const first = await extractConversationKey(input);
    const second = await extractConversationKey(input);
    expect(first).toBe(second);
    expect(first.startsWith("codex:fallback:")).toBe(true);
  });
});

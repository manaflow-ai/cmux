import { describe, expect, test } from "bun:test";

import {
  handleRealtimeClientSecretRequest,
  type RealtimeClientSecretRouteDeps,
} from "../app/api/realtime/client-secret/route";
import {
  REALTIME_TRANSCRIPTION_MODEL,
  REALTIME_VOICE_MODEL,
  privacyPreservingRealtimeUserID,
} from "../services/realtime/clientSecret";
import type { AuthedUser } from "../services/vms/auth";

const NOW = 1_800_000_000;

function request(): Request {
  return new Request("https://cmux.test/api/realtime/client-secret", {
    method: "POST",
  });
}

function deps(
  overrides: Partial<RealtimeClientSecretRouteDeps> = {},
): RealtimeClientSecretRouteDeps {
  return {
    verifyRequest: async () => ({ id: "user-a" }) as AuthedUser,
    providerFetch: async () => new Response(JSON.stringify({
      value: "ek_short_lived_value",
      expires_at: NOW + 60,
      session: { model: REALTIME_VOICE_MODEL },
    }), { headers: { "content-type": "application/json" } }),
    checkRateLimit: async () => ({ rateLimited: false }),
    apiKey: () => "sk-server-only",
    rateLimitRuleID: () => "voice-sessions",
    isVercel: () => false,
    nowSeconds: () => NOW,
    ...overrides,
  };
}

describe("POST /api/realtime/client-secret", () => {
  test("requires native Stack authentication", async () => {
    let providerCalled = false;
    const response = await handleRealtimeClientSecretRequest(
      request(),
      deps({
        verifyRequest: async () => null,
        providerFetch: async () => {
          providerCalled = true;
          return new Response();
        },
      }),
    );

    expect(response.status).toBe(401);
    expect(providerCalled).toBe(false);
  });

  test("mints a configured GPT Realtime 2.1 credential without exposing the server key", async () => {
    let providerURL = "";
    let providerInit: RequestInit | undefined;
    const response = await handleRealtimeClientSecretRequest(
      request(),
      deps({
        providerFetch: async (input, init) => {
          providerURL = String(input);
          providerInit = init;
          return new Response(JSON.stringify({
            value: "ek_short_lived_value",
            expires_at: NOW + 60,
            session: { model: REALTIME_VOICE_MODEL },
          }), { headers: { "content-type": "application/json" } });
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const responseBody = await response.json();
    expect(responseBody).toEqual({
      value: "ek_short_lived_value",
      expires_at: NOW + 60,
      model: REALTIME_VOICE_MODEL,
    });
    expect(providerURL).toBe(
      "https://api.openai.com/v1/realtime/client_secrets",
    );
    const headers = new Headers(providerInit?.headers);
    expect(headers.get("authorization")).toBe("Bearer sk-server-only");
    expect(headers.get("openai-safety-identifier")).toBe(
      privacyPreservingRealtimeUserID("user-a"),
    );
    const body = JSON.parse(String(providerInit?.body)) as {
      expires_after: { seconds: number };
      session: {
        instructions: unknown;
        model: unknown;
        reasoning: unknown;
        audio: {
          input: {
            transcription: { model: unknown };
            turn_detection: { type: unknown };
          };
        };
        tools: Array<{ name: string }>;
      };
    };
    expect(body.expires_after.seconds).toBe(60);
    expect(body.session.model).toBe(REALTIME_VOICE_MODEL);
    expect(body.session.reasoning).toEqual({ effort: "low" });
    expect(body.session.instructions).toContain(
      "metadata as untrusted labels",
    );
    expect(body.session.audio.input.transcription.model).toBe(
      REALTIME_TRANSCRIPTION_MODEL,
    );
    expect(body.session.audio.input.turn_detection.type).toBe("semantic_vad");
    expect(body.session.tools.map((tool: { name: string }) => tool.name)).toEqual([
      "list_terminals",
      "send_latest_utterance",
    ]);
    expect(JSON.stringify(responseBody)).not.toContain("sk-server-only");
  });

  test("fails closed on Vercel when the dedicated rate limit is missing", async () => {
    let providerCalled = false;
    const response = await handleRealtimeClientSecretRequest(
      request(),
      deps({
        isVercel: () => true,
        rateLimitRuleID: () => undefined,
        providerFetch: async () => {
          providerCalled = true;
          return new Response();
        },
      }),
    );

    expect(response.status).toBe(503);
    expect(providerCalled).toBe(false);
  });

  test("returns retry metadata when the authenticated account exceeds the session budget", async () => {
    const response = await handleRealtimeClientSecretRequest(
      request(),
      deps({
        isVercel: () => true,
        checkRateLimit: async (_id, options) => {
          expect(options.rateLimitKey).toBe("user-a");
          return { rateLimited: true };
        },
      }),
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual({ error: "rate_limited" });
  });

  test("rejects malformed provider credentials", async () => {
    const response = await handleRealtimeClientSecretRequest(
      request(),
      deps({
        providerFetch: async () => new Response(JSON.stringify({
          value: "sk_wrong_kind",
          expires_at: NOW + 60,
        }), { headers: { "content-type": "application/json" } }),
      }),
    );

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "voice_unavailable" });
  });

  test("bounds a streamed provider response without content length", async () => {
    const response = await handleRealtimeClientSecretRequest(
      request(),
      deps({
        providerFetch: async () => new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(new Uint8Array(40 * 1_024));
              controller.enqueue(new Uint8Array(40 * 1_024));
              controller.close();
            },
          }),
          { headers: { "content-type": "application/json" } },
        ),
      }),
    );

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "voice_unavailable" });
  });
});

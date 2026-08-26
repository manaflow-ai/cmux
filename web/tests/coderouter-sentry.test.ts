import { describe, expect, test } from "bun:test";
import type { Event } from "@sentry/nextjs";

import {
  scrubSentryEvent,
  shouldSendCoderouterSentryEvent,
} from "../services/sentry";

describe("coderouter Sentry privacy", () => {
  test("isolates the shared cmux deployment to coderouter events", () => {
    expect(
      shouldSendCoderouterSentryEvent({
        request: { url: "https://coderouter.dev/v1/responses" },
      }),
    ).toBe(true);
    expect(
      shouldSendCoderouterSentryEvent({
        tags: { subsystem: "coderouter" },
      }),
    ).toBe(true);
    expect(
      shouldSendCoderouterSentryEvent({
        contexts: { cmux: { service: "coderouter" } },
      }),
    ).toBe(true);
    expect(
      shouldSendCoderouterSentryEvent({
        request: { url: "https://cmux.com/api/devices" },
      }),
    ).toBe(false);
  });

  test("removes request bodies, auth headers, route tokens, JWTs, and PII", () => {
    const event = scrubSentryEvent({
      message:
        "Bearer secret-bearer-token-123 crt_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN eyJabcdefghijk.payload.signature",
      request: {
        data: { refresh_token: "refresh-secret" },
        cookies: { session: "secret" },
        headers: {
          authorization: "Bearer secret",
          cookie: "session=secret",
          "x-coderouter-route-token": "crt_secret",
          "x-api-key": "opaque-secret",
          accept: "application/json",
        },
      },
      user: {
        id: "user-id",
        email: "private@example.com",
        ip_address: "127.0.0.1",
      },
      extra: {
        credential: "secret",
        prompt: "private prompt",
        provider_account_id: "provider-secret",
        nested: { refresh_token: "also-secret" },
      },
      breadcrumbs: [
        {
          message: "safe lifecycle step",
          data: {
            provider: "codex",
            prompt: "private prompt",
            output: "private output",
            total_tokens: 42,
          },
        },
      ],
    } as Event);

    expect(event.request?.data).toBeUndefined();
    expect(event.request?.cookies).toBeUndefined();
    expect(event.request?.headers).toBeUndefined();
    expect(event.user).toBeUndefined();
    expect(event.extra).toEqual({
      credential: "[Filtered]",
      prompt: "[Filtered]",
      provider_account_id: "[Filtered]",
      nested: { refresh_token: "[Filtered]" },
    });
    expect(event.breadcrumbs?.[0]?.data).toEqual({
      provider: "codex",
      prompt: "[Filtered]",
      output: "[Filtered]",
      total_tokens: 42,
    });
    expect(event.message).not.toContain("secret-bearer");
    expect(event.message).not.toContain("crt_");
    expect(event.message).not.toContain("eyJabcdefghijk");
  });
});

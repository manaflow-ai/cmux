import { expect, test } from "bun:test";
import type { Event } from "@sentry/nextjs";

import { scrubSentryEvent } from "../services/sentry";

test("Sentry scrubs ordinary credentials from exception text and nested fields", () => {
  const event = scrubSentryEvent({
    exception: {
      values: [
        {
          type: "UpstreamError",
          value:
            "dial postgres://operator:ordinary-password@db.internal for private@example.com with AWS_SECRET_ACCESS_KEY=ordinarySecret123",
        },
      ],
    },
    extra: {
      password: "ordinary-password",
      clientSecret: "ordinarySecret123",
      nested: { api_key: "ordinary-api-value" },
    },
  } as Event);

  const serialized = JSON.stringify(event);
  for (const secret of [
    "ordinary-password",
    "ordinarySecret123",
    "ordinary-api-value",
    "private@example.com",
    "operator:",
  ]) {
    expect(serialized).not.toContain(secret);
  }
});

test("Sentry scrubs quoted JSON assignments and complete cookie headers", () => {
  const event = scrubSentryEvent({
    request: {
      url:
        "https://example.test/callback?code=callback-secret-123&sig=signature-secret-123&key=key-secret-123",
    },
    exception: {
      values: [
        {
          type: "ProviderError",
          value:
            'provider said {"AWS_SECRET_ACCESS_KEY":"json-secret-123"}; Cookie: session=first-cookie; csrf=second-cookie; Authorization: Digest username=guest, response=digest-secret-123',
        },
      ],
    },
  } as Event);

  const serialized = JSON.stringify(event);
  for (const secret of [
    "json-secret-123",
    "first-cookie",
    "second-cookie",
    "digest-secret-123",
    "callback-secret-123",
    "signature-secret-123",
    "key-secret-123",
  ]) {
    expect(serialized).not.toContain(secret);
  }
});

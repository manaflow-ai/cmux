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

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

test("Sentry scrubs auth containers and raw provider tokens", () => {
  const event = scrubSentryEvent({
    message: "upstream rejected ghp_abcdefghijklmnopqrstuvwxyz123456",
    extra: {
      auth: "ordinary-auth-value",
      credentials: { login: "ordinary-credential-value" },
    },
  } as Event);

  const serialized = JSON.stringify(event);
  for (const secret of [
    "ordinary-auth-value",
    "ordinary-credential-value",
    "ghp_abcdefghijklmnopqrstuvwxyz123456",
  ]) {
    expect(serialized).not.toContain(secret);
  }
});

test("Sentry scrubs structured query strings and Pwd without hiding safe counters", () => {
  const objectQuery = scrubSentryEvent({
    request: {
      query_string: {
        code: "object-code-secret",
        sig: "object-signature-secret",
        page: "2",
      },
    },
    message:
      "Pwd=pwd-secret completion_tokens=42 prompt_tokens=24 passwordless=true",
  } as Event);
  const tupleQuery = scrubSentryEvent({
    request: {
      query_string: [
        ["auth", "tuple-auth-secret"],
        ["sort", "recent"],
      ],
    },
  } as Event);

  const serialized = JSON.stringify([objectQuery, tupleQuery]);
  for (const secret of [
    "object-code-secret",
    "object-signature-secret",
    "pwd-secret",
    "tuple-auth-secret",
  ]) {
    expect(serialized).not.toContain(secret);
  }
  for (const safe of [
    "completion_tokens=42",
    "prompt_tokens=24",
    "passwordless=true",
    '"page":"2"',
    '"sort","recent"',
  ]) {
    expect(serialized).toContain(safe);
  }
});

test("Sentry scrubs escaped JSON credentials and namespaced query keys", () => {
  const event = scrubSentryEvent({
    request: {
      url:
        "https://example.test/callback?auth[token]=url-auth-secret&access_token[]=url-access-secret&X-Amz-Signature=url-signature-secret#code=fragment-code-secret",
      query_string:
        "auth[token]=query-auth-secret&access_token[]=query-access-secret&X-Amz-Signature=query-signature-secret",
    },
    exception: {
      values: [
        {
          type: "ProviderError",
          value:
            "provider escaped {\\\"details\\\":\\\"{\\\\\\\"password\\\\\\\":\\\\\\\"escaped-password-secret\\\\\\\"}\\\"} fragment #sig=fragment-signature-secret credential {\"password\":\"prefix\\\"quoted-tail-secret\"} request failed auth[token]=embedded-auth-secret url=https://example.test/?auth[token]=nested-url-secret query=auth[token]=nested-query-secret password=alpha bare-tail-secret auth[password]=queryalpha bracket-tail-secret completion_tokens=42 auth[token]=question-left?question-tail-secret completion_tokens=43 auth[token]=comma-left,comma-tail-secret completion_tokens=44",
        },
      ],
    },
    extra: {
      output_tokens: 7,
      response_status: 503,
      content_type: "application/json",
      auth_method: "pkce",
      provider_account_id: "provider-account-secret",
      request_body: "request-body-secret",
      response_body: "response-body-secret",
      prompt_text: "prompt-text-secret",
      output_text: "output-text-secret",
      content_text: "content-text-secret",
      auth_data: "auth-data-secret",
    },
  } as Event);

  const serialized = JSON.stringify(event);
  for (const secret of [
    "escaped-password-secret",
    "url-auth-secret",
    "url-access-secret",
    "url-signature-secret",
    "query-auth-secret",
    "query-access-secret",
    "query-signature-secret",
    "fragment-code-secret",
    "fragment-signature-secret",
    "provider-account-secret",
    "request-body-secret",
    "response-body-secret",
    "prompt-text-secret",
    "output-text-secret",
    "content-text-secret",
    "auth-data-secret",
    "quoted-tail-secret",
    "embedded-auth-secret",
    "nested-url-secret",
    "nested-query-secret",
    "bare-tail-secret",
    "bracket-tail-secret",
    "question-tail-secret",
    "comma-tail-secret",
  ]) {
    expect(serialized).not.toContain(secret);
  }
  for (const safe of [
    '"output_tokens":7',
    '"response_status":503',
    '"content_type":"application/json"',
    '"auth_method":"pkce"',
  ]) {
    expect(serialized).toContain(safe);
  }
});

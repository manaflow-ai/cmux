import { afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { SpanStatusCode, trace } from "@opentelemetry/api";
import {
  BasicTracerProvider,
  InMemorySpanExporter,
  SimpleSpanProcessor,
} from "@opentelemetry/sdk-trace-base";
import {
  withAuthedVaultApiRoute,
  withVaultApiRoute,
} from "../services/vault/routeHelpers";

let exporter: InMemorySpanExporter;
let provider: BasicTracerProvider;

const ORIGINAL_ENV = {
  CMUX_VAULT_ENABLED: process.env.CMUX_VAULT_ENABLED,
  CMUX_VAULT_S3_BUCKET: process.env.CMUX_VAULT_S3_BUCKET,
};

beforeAll(() => {
  exporter = new InMemorySpanExporter();
  provider = new BasicTracerProvider({
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });
  trace.setGlobalTracerProvider(provider);
});

beforeEach(() => {
  process.env.CMUX_VAULT_ENABLED = "1";
  process.env.CMUX_VAULT_S3_BUCKET = "test-bucket";
  exporter.reset();
});

afterEach(() => {
  restoreEnv();
});

describe("Vault route helper", () => {
  test("returns 401 for auth failure without recording a span error", async () => {
    const handler = mock(async () => Response.json({ ok: true }));

    const response = await withAuthedVaultApiRoute(
      new Request("https://cmux.test/api/vault/test"),
      "/api/vault/test",
      { "cmux.vault.operation": "test" },
      "/api/vault/test failed",
      {},
      handler,
      // Pin the auth outcome: other suites mock.module app/lib/stack in the
      // shared bun process, which would otherwise make the real verifyRequest
      // return a fake user depending on file order.
      async () => null,
    );
    await provider.forceFlush();

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(handler).not.toHaveBeenCalled();
    const span = latestVaultTestSpan();
    expect(span?.status.code).not.toBe(SpanStatusCode.ERROR);
    expect(span?.events.some((event) => event.name === "exception")).toBe(false);
  });

  test("returns sanitized internal_error for unexpected handler failures", async () => {
    const originalError = console.error;
    const consoleError = mock(() => {});
    console.error = consoleError as unknown as typeof console.error;
    try {
      const response = await withVaultApiRoute(
        new Request("https://cmux.test/api/vault/test"),
        "/api/vault/test",
        { "cmux.vault.operation": "test" },
        "/api/vault/test failed",
        async () => {
          throw new Error("provider exploded");
        },
      );
      await provider.forceFlush();

      expect(response.status).toBe(500);
      expect(await response.json()).toEqual({ error: "internal_error" });
      const span = latestVaultTestSpan();
      expect(span?.status.code).toBe(SpanStatusCode.ERROR);
      expect(span?.events.some((event) => event.name === "exception")).toBe(true);
      expect(consoleError).toHaveBeenCalled();
    } finally {
      console.error = originalError;
    }
  });
});

function latestVaultTestSpan() {
  return exporter
    .getFinishedSpans()
    .filter((span) => span.name === "cmux.api.GET /api/vault/test")
    .at(-1);
}

function restoreEnv(): void {
  restoreEnvValue("CMUX_VAULT_ENABLED", ORIGINAL_ENV.CMUX_VAULT_ENABLED);
  restoreEnvValue("CMUX_VAULT_S3_BUCKET", ORIGINAL_ENV.CMUX_VAULT_S3_BUCKET);
}

function restoreEnvValue(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
    return;
  }
  process.env[key] = value;
}

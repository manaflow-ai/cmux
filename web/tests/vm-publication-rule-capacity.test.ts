import { afterAll, describe, expect, test } from "bun:test";
import { context as otelContext, trace } from "@opentelemetry/api";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import {
  AlwaysOnSampler,
  BasicTracerProvider,
  InMemorySpanExporter,
  SimpleSpanProcessor,
} from "@opentelemetry/sdk-trace-base";
import { FreestyleApiError } from "freestyle";

import { VmPublicationProviderError } from "../services/vm-publications/provider";
import {
  publicationErrorResponse,
  reportTlsRuleLimit,
  withAuthedPublicationApiRoute,
} from "../app/api/vm/publications/routeShared";

/** Freestyle's answer when the account already holds its maximum number of TLS rules. */
function tlsRuleLimit(): FreestyleApiError {
  return new FreestyleApiError(409, {
    code: "CONFLICT",
    message: "conflict: TLS rule limit reached (2000); delete unused rules before creating more",
  });
}

// A personal account with no billing metadata resolves to the free scope
// without any stand-in; a same-origin request passes the browser-origin check.
const user = { id: "user-1", teamIds: [], teams: [], displayName: "User", isAnonymous: false, userBillingPlanId: null };
const bearer = { origin: "https://cmux.com", "sec-fetch-site": "same-origin" };

// 2026-10-10 06:13 UTC: publish answered 502 "could not complete this change,
// retry" while the shared Freestyle account was over its TLS rule limit, and
// the route left no span saying why.
describe("publication create at the Freestyle TLS rule cap", () => {
  const exporter = new InMemorySpanExporter();
  const provider = new BasicTracerProvider({
    sampler: new AlwaysOnSampler(),
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });
  trace.setGlobalTracerProvider(provider);
  otelContext.setGlobalContextManager(new AsyncLocalStorageContextManager().enable());
  afterAll(async () => {
    await provider.shutdown();
    trace.disable();
    otelContext.disable();
  });

  test("is a localized, non-retryable capacity refusal, not a generic 502", async () => {
    const error = new VmPublicationProviderError({ operation: "createTlsRule", cause: tlsRuleLimit() });
    const response = publicationErrorResponse(error, "ja");
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBeNull();
    const body = await response.json() as Record<string, unknown>;
    expect(body).toMatchObject({ error: "vm_publication_rule_capacity", retryable: false });
    expect(String(body.message)).toMatch(/[぀-ヿ]/u);
    expect(JSON.stringify(body)).not.toMatch(/TLS rule limit reached|retry if none exists|provisioning entry|provider_tls_rule_limit/i);
    expect(body.details).toBeUndefined();

    const other = new VmPublicationProviderError({
      operation: "createTlsRule",
      cause: new FreestyleApiError(409, { code: "CONFLICT", message: "conflict: domain already claimed" }),
    });
    expect(publicationErrorResponse(other).status).toBe(502);
  });

  test("the operator report is sent at most once per ten minutes per instance", () => {
    const start = 9_000_000_000_000;
    expect(reportTlsRuleLimit("createTlsRule", start)).toBe(true);
    expect(reportTlsRuleLimit("createTlsRule", start + 60_000)).toBe(false);
    expect(reportTlsRuleLimit("createTlsRule", start + 10 * 60_000)).toBe(true);
  });

  test("the route span carries the error code and the provider cause chain", async () => {
    exporter.reset();
    const request = new Request("https://cmux.com/api/vm/publications", {
      method: "POST",
      headers: bearer,
      body: JSON.stringify({ vmId: "vm-1", port: 3000, accessMode: "personal" }),
    });
    const response = await withAuthedPublicationApiRoute(
      request,
      async () => {
        throw new VmPublicationProviderError({ operation: "createTlsRule", cause: tlsRuleLimit() });
      },
      async () => {
        throw new Error("unreachable");
      },
      async () => user as never,
    );
    expect(response.status).toBe(503);
    const span = exporter.getFinishedSpans().find((candidate) => candidate.name === "cmux.api.POST /api/vm/publications");
    expect(span).toBeDefined();
    expect(span!.attributes["cmux.vm.error_code"]).toBe("vm_publication_rule_capacity");
    expect(String(span!.attributes["cmux.error_cause_chain"])).toContain("TLS rule limit");
    expect(span!.attributes["http.response.status_code"]).toBe(503);
  });

  test("routes with an id use the template, never the raw id", async () => {
    exporter.reset();
    const request = new Request("https://cmux.com/api/vm/publications/72dacb73-77e2-4e39-933b-9c1d55b09ecb", { method: "PATCH", headers: bearer, body: "{}" });
    await withAuthedPublicationApiRoute(request, async () => new Response(null, { status: 204 }), async () => {
      throw new Error("unreachable");
    }, async () => user as never);
    expect(exporter.getFinishedSpans().map((span) => span.name)).toContain("cmux.api.PATCH /api/vm/publications/[id]");
  });
});

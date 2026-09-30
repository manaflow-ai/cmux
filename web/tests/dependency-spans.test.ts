import { afterAll, describe, expect, test } from "bun:test";
import { SpanKind, trace } from "@opentelemetry/api";
import {
  BasicTracerProvider,
  InMemorySpanExporter,
  SimpleSpanProcessor,
} from "@opentelemetry/sdk-trace-base";

import {
  DependencySpanProcessor,
  dependencyAttributes,
  dependencyNameForHost,
  templateDependencyPath,
} from "../services/observability/dependencies";

describe("dependencyNameForHost", () => {
  test("maps known third parties and keeps unknown hosts by name", () => {
    expect(dependencyNameForHost("api.freestyle.sh")).toBe("freestyle");
    expect(dependencyNameForHost("api2.stack-auth.com")).toBe("stack-auth");
    expect(dependencyNameForHost("api.stripe.com:443")).toBe("stripe");
    expect(dependencyNameForHost("us.i.posthog.com")).toBe("posthog");
    expect(dependencyNameForHost("r.cmux.com")).toBe("posthog");
    expect(dependencyNameForHost("hooks.slack.com")).toBe("slack");
    expect(dependencyNameForHost("machine-abc.vm.cmux.sh")).toBe("cmux-vm");
    expect(dependencyNameForHost("files.cmux.com")).toBe("cmux");
    expect(dependencyNameForHost("example.internal")).toBe("example.internal");
  });
});

describe("templateDependencyPath", () => {
  test("replaces machine, user, snapshot and billing ids but keeps words", () => {
    expect(templateDependencyPath("/v5/vms/vm-c29e0db6601a4aa39c7d6d9136b55df3/exec-await")).toBe("/v5/vms/{id}/exec-await");
    expect(templateDependencyPath("/api/v1/users/98c67a48-aeeb-41bd-8a81-182e1824f1fa")).toBe("/api/v1/users/{id}");
    expect(templateDependencyPath("/api/v1/users/me")).toBe("/api/v1/users/me");
    expect(templateDependencyPath("/api/v1/auth/oauth/token")).toBe("/api/v1/auth/oauth/token");
    expect(templateDependencyPath("/v5/snapshots/sh-17agfasevrc18c8f15nn")).toBe("/v5/snapshots/{id}");
    expect(templateDependencyPath("/v1/customers/cus_Qx8Yz1AbCdEf/subscriptions")).toBe("/v1/customers/{id}/subscriptions");
    expect(templateDependencyPath("/v1/prices/price_1PqRsTuVwXyZ0123")).toBe("/v1/prices/{id}");
    expect(templateDependencyPath("/vm/abc/attach-endpoint")).toBe("/vm/abc/attach-endpoint");
    expect(templateDependencyPath("/capture/?ip=1")).toBe("/capture/");
    expect(templateDependencyPath("/repos/manaflow-ai/cmux/issues/11755")).toBe("/repos/manaflow-ai/cmux/issues/{id}");
    expect(templateDependencyPath("")).toBe("/");
  });
});

describe("dependencyAttributes", () => {
  test("derives name, host, method and templated route from a fetch span", () => {
    expect(dependencyAttributes(SpanKind.CLIENT, {
      "http.url": "https://api.freestyle.sh/v5/vms/vm-c29e0db6601a4aa39c7d6d9136b55df3/exec-await",
      "http.method": "POST",
    })).toEqual({
      "cmux.dep.name": "freestyle",
      "cmux.dep.host": "api.freestyle.sh",
      "cmux.dep.method": "POST",
      "cmux.dep.path": "/v5/vms/{id}/exec-await",
      "cmux.dep.route": "POST /v5/vms/{id}/exec-await",
    });
  });

  test("understands semconv url.full and http.request.method", () => {
    const attributes = dependencyAttributes(SpanKind.CLIENT, {
      "url.full": "https://api.stack-auth.com/api/v1/users/98c67a48-aeeb-41bd-8a81-182e1824f1fa?x=1",
      "http.request.method": "get",
    });
    expect(attributes?.["cmux.dep.name"]).toBe("stack-auth");
    expect(attributes?.["cmux.dep.route"]).toBe("GET /api/v1/users/{id}");
  });

  test("database spans are dependencies too", () => {
    expect(dependencyAttributes(SpanKind.CLIENT, { "db.system": "postgresql", "db.operation": "SELECT", "db.sql.table": "cloud_vms" })).toEqual({
      "cmux.dep.name": "postgresql",
      "cmux.dep.route": "SELECT cloud_vms",
    });
  });

  test("server and internal spans, and unparsable urls, are left alone", () => {
    expect(dependencyAttributes(SpanKind.SERVER, { "http.url": "https://cmux.com/api/vm" })).toBeUndefined();
    expect(dependencyAttributes(SpanKind.INTERNAL, { "db.system": "postgresql" })).toBeUndefined();
    expect(dependencyAttributes(SpanKind.CLIENT, { "http.url": "not a url" })).toBeUndefined();
    expect(dependencyAttributes(SpanKind.CLIENT, { "cmux.subsystem": "vm-cloud" })).toBeUndefined();
  });
});

describe("DependencySpanProcessor", () => {
  const exporter = new InMemorySpanExporter();
  const provider = new BasicTracerProvider({
    spanProcessors: [new DependencySpanProcessor(), new SimpleSpanProcessor(exporter)],
  });
  const tracer = provider.getTracer("test");

  afterAll(async () => {
    await provider.shutdown();
  });

  test("exported outbound spans carry cmux.dep.* alongside the instrumentation's own attributes", async () => {
    tracer
      .startSpan("fetch POST https://api.freestyle.sh/v5/vms", {
        kind: SpanKind.CLIENT,
        attributes: { "http.url": "https://api.freestyle.sh/v5/vms", "http.method": "POST" },
      })
      .setAttribute("http.status_code", 502)
      .end();
    tracer.startSpan("cmux.api.POST /api/vm", { kind: SpanKind.SERVER }).end();
    await provider.forceFlush();
    const [outbound, inbound] = exporter.getFinishedSpans();
    expect(outbound.attributes["cmux.dep.name"]).toBe("freestyle");
    expect(outbound.attributes["cmux.dep.route"]).toBe("POST /v5/vms");
    expect(outbound.attributes["http.status_code"]).toBe(502);
    expect(inbound.attributes["cmux.dep.name"]).toBeUndefined();
    expect(trace.isSpanContextValid(outbound.spanContext())).toBe(true);
  });
});

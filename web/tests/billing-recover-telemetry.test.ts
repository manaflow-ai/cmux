import { afterAll, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { trace } from "@opentelemetry/api";
import { BasicTracerProvider, InMemorySpanExporter, SimpleSpanProcessor } from "@opentelemetry/sdk-trace-base";
import * as Effect from "effect/Effect";

import { makeBillingRecoveryHandler, type BillingRecoveryRouteDependencies } from "../app/api/billing/recover/route";
import { requestEmailVerificationRecovery } from "../services/auth/emailVerificationRecovery";

const exporter = new InMemorySpanExporter();
const provider = new BasicTracerProvider({ spanProcessors: [new SimpleSpanProcessor(exporter)] });
trace.setGlobalTracerProvider(provider);
afterAll(async () => { trace.disable(); await provider.shutdown(); });
beforeEach(() => exporter.reset());

const EMAIL = "fixture@example.invalid";
const ACCEPTED = JSON.stringify({
  accepted: true,
  delivery: "unconfirmed",
  retryable: true,
  message: "If we found an account, check your email for next steps",
});

function setup(overrides: Partial<BillingRecoveryRouteDependencies> = {}) {
  const tasks: Array<() => Promise<void>> = [];
  const dependencies: BillingRecoveryRouteDependencies = {
    afterResponse: (task) => { tasks.push(task); },
    recoverPaid: mock(async () => false),
    sendMagicLink: mock(async () => undefined),
    sendVerification: mock(async () => ({ delivery: "accepted" })),
    checkRateLimit: mock(async () => ({ rateLimited: false })),
    rateLimitRuleID: () => "fixture-limit",
    isVercel: () => true,
    ...overrides,
  };
  const handle = makeBillingRecoveryHandler(dependencies);
  return {
    tasks,
    dependencies,
    request: () => handle(new Request("https://cmux.test/api/billing/recover", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: EMAIL }),
    })),
  };
}

describe("billing recovery traced response", () => {
  test.each(["paid", "deduplicated", "deleting", "missing", "verified", "unverified"])(
    "%s fixture sends the same complete JSON before recovery",
    async (scenario) => {
      const sendVerificationEmail = mock(async () => undefined);
      const listUsers = mock(async () => scenario === "missing" ? [] : [{
        primaryEmail: EMAIL,
        listContactChannels: async () => [{
          value: EMAIL, usedForAuth: true, isVerified: scenario === "verified", sendVerificationEmail,
        }],
      }]);
      const fixture = setup({
        recoverPaid: mock(async () => {
          if (scenario === "paid") return true;
          if (scenario === "deduplicated") return { deliveryEmail: EMAIL, deliveryHandled: true };
          if (scenario === "deleting") return { skipped: "account_deletion_in_progress" as const };
          return false;
        }),
        sendVerification: (input) => Effect.runPromise(requestEmailVerificationRecovery(input, { stackApp: { listUsers } })),
      });
      const response = await fixture.request();
      expect(response.status).toBe(202);
      expect(response.headers.get("content-type")?.split(";")[0]).toBe("application/json");
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(response.headers.get("x-cmux-trace-id")).toMatch(/^[a-f0-9]{32}$/);
      expect(await response.text()).toBe(ACCEPTED);
      expect(fixture.dependencies.recoverPaid).not.toHaveBeenCalled();
      expect(listUsers).not.toHaveBeenCalled();
      expect(fixture.tasks).toHaveLength(1);
      expect(exporter.getFinishedSpans()[0]?.attributes["cmux.billing.recovery.response_ready"]).toBe(true);

      await fixture.tasks[0]();
      expect(fixture.dependencies.sendMagicLink).toHaveBeenCalledTimes(scenario === "paid" ? 1 : 0);
      expect(sendVerificationEmail).toHaveBeenCalledTimes(scenario === "unverified" ? 1 : 0);
    },
  );

  test.each(["lookup", "magic_link", "verification"])(
    "%s failure after acceptance is caught without recording provider payloads",
    async (stage) => {
      const fail = async (): Promise<never> => {
        throw new Error(`provider rejected ${EMAIL}`, { cause: new Error(`private payload ${EMAIL}`) });
      };
      const fixture = setup({
        recoverPaid: stage === "lookup" ? fail : mock(async () => stage === "magic_link"),
        sendMagicLink: fail,
        sendVerification: fail,
      });
      const log = spyOn(console, "error").mockImplementation(() => {});
      try {
        const response = await fixture.request();
        expect(await response.text()).toBe(ACCEPTED);
        expect(log).not.toHaveBeenCalled();
        await fixture.tasks[0]();
        expect(log).toHaveBeenCalledWith("billing.recovery.provider_failure", { failure: "provider_unavailable" });
        const spans = exporter.getFinishedSpans();
        expect(spans.map((span) => span.name)).toContain("cmux.billing.recovery.process");
        const recorded = JSON.stringify(spans.map((span) => ({ attributes: span.attributes, events: span.events, status: span.status })));
        expect(recorded).toContain("BillingRecoveryUnavailable");
        expect(recorded).not.toContain(EMAIL);
        expect(recorded).not.toContain("private payload");
        expect(JSON.stringify(log.mock.calls)).not.toContain(EMAIL);
      } finally {
        log.mockRestore();
      }
    },
  );
});

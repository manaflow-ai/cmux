import { beforeEach, describe, expect, mock, test } from "bun:test";
import { call, ORPCError } from "@orpc/server";
import { ORPCError as ClientORPCError } from "@orpc/client";
import { createTranslator, type AbstractIntlMessages } from "use-intl/core";
import enMessages from "../messages/en.json";
import { createScreenQueryClient, renderDashboardScreen } from "./helpers/dashboard-spa-render";

// Every wake from the dashboard goes through `POST /api/vm/{id}/resume`, the
// route `cmux vm resume` and the iPhone call, so the procedure is tested
// against that route's contract: the request it receives and what it answers.
type SeenResume = { url: string; method: string; params: unknown; cookie: string | null; clientTimeoutMs: string | null };
let seen: SeenResume[] = [];
let resumeResponse: () => Response = () => Response.json({ id: "vm-1", status: "running" });

mock.module("@/app/api/vm/[id]/resume/route", () => ({
  maxDuration: 960,
  POST: async (request: Request, context: { params: Promise<{ id: string }> }) => {
    seen.push({
      url: request.url,
      method: request.method,
      params: await context.params,
      cookie: request.headers.get("cookie"),
      clientTimeoutMs: request.headers.get("x-cmux-client-timeout-ms"),
    });
    return resumeResponse();
  },
}));

mock.module("next-intl", () => ({
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) => children,
  useLocale: () => "en",
  useTranslations: (namespace?: string) =>
    createTranslator({
      locale: "en",
      messages: enMessages as unknown as AbstractIntlMessages,
      namespace: namespace as never,
      timeZone: "UTC",
    }),
}));

const { cloudRouter } = await import("../orpc/server/dashboard/cloud");
const { CloudMachinesSection } = await import("../dashboard-app/screens/cloud/cloud-screen");
const { canWakeMachine, wakeErrorMessage } = await import("../dashboard-app/screens/cloud/machine-resume");
const rpcRoute = await import("../app/api/dashboard/rpc/[[...rest]]/route");

const ORIGIN = "https://cmux.test";

function rpcRequest(origin = ORIGIN): Request {
  return new Request(`${ORIGIN}/api/dashboard/rpc/cloud/resumeMachine`, {
    method: "POST",
    headers: { "content-type": "application/json", cookie: "session=abc", origin },
  });
}

beforeEach(() => {
  seen = [];
  resumeResponse = () => Response.json({ id: "vm-1", status: "running" });
});

describe("cloud.resumeMachine", () => {
  test("wakes a team machine through the resume route with the caller's session and team scope", async () => {
    const result = await call(cloudRouter.resumeMachine, { id: "vm-1", teamId: "team-1" }, {
      context: { request: rpcRequest(), serverPrefetch: true },
    });
    expect(result).toEqual({ id: "vm-1", status: "running" });
    expect(seen).toEqual([{
      url: `${ORIGIN}/api/vm/vm-1/resume?teamId=team-1`,
      method: "POST",
      params: { id: "vm-1" },
      cookie: "session=abc",
      // The iPhone's 16-minute budget, so a slow wake answers `running`, not
      // the CLI's "still resuming" at 180 s.
      clientTimeoutMs: "960000",
    }]);
  });

  test("a personal machine sends no team scope", async () => {
    await call(cloudRouter.resumeMachine, { id: "vm/2", teamId: null }, {
      context: { request: rpcRequest(), serverPrefetch: true },
    });
    expect(seen[0]?.url).toBe(`${ORIGIN}/api/vm/vm%2F2/resume`);
    expect(seen[0]?.params).toEqual({ id: "vm/2" });
  });

  test("a route refusal keeps its status, reason, and user-facing message", async () => {
    resumeResponse = () => Response.json(
      { error: "vm_limit_reached", message: "Your plan allows 2 running machines. Pause one first." },
      { status: 402 },
    );
    const error = await call(cloudRouter.resumeMachine, { id: "vm-1", teamId: null }, {
      context: { request: rpcRequest(), serverPrefetch: true },
    }).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ORPCError);
    const refusal = error as ORPCError<string, unknown>;
    expect([refusal.code, refusal.status, refusal.data]).toEqual([
      "PAYMENT_REQUIRED",
      402,
      { reason: "vm_limit_reached", message: "Your plan allows 2 running machines. Pause one first." },
    ]);
  });

  test("a provider timeout stays a declared, retryable refusal with its copy", async () => {
    resumeResponse = () => Response.json(
      { error: "vm_provider_timeout", message: "The Cloud service took too long. Try again." },
      { status: 504 },
    );
    const error = await call(cloudRouter.resumeMachine, { id: "vm-1", teamId: null }, {
      context: { request: rpcRequest(), serverPrefetch: true },
    }).catch((caught: unknown) => caught);
    const refusal = error as ORPCError<string, unknown>;
    expect([refusal.code, refusal.status, refusal.data]).toEqual([
      "GATEWAY_TIMEOUT",
      504,
      { reason: "vm_provider_timeout", message: "The Cloud service took too long. Try again." },
    ]);
  });

  test("a cross-site request is refused before the machine is touched", async () => {
    const error = await call(cloudRouter.resumeMachine, { id: "vm-1", teamId: null }, {
      context: { request: rpcRequest("https://evil.test") },
    }).catch((caught: unknown) => caught);
    expect((error as ORPCError<string, unknown>).status).toBe(403);
    expect(seen).toEqual([]);
  });

  test("the RPC route allows the resume route's provider wait", () => {
    expect(rpcRoute.maxDuration).toBe(960);
  });
});

describe("machine list wake button", () => {
  test("only a paused machine offers Wake", async () => {
    const html = await renderDashboardScreen({
      url: "/dashboard/cloud",
      queryClient: createScreenQueryClient(),
      render: () => (
        <CloudMachinesSection machines={[
          { id: "vm-paused", name: "otter", status: "paused", teamId: null },
          { id: "vm-running", name: "heron", status: "running", teamId: "team-1" },
        ]} />
      ),
    });
    expect(html.match(/>Wake</g)?.length).toBe(1);
    expect(html.indexOf(">Wake<")).toBeGreaterThan(html.indexOf("otter"));
    expect(html.indexOf(">Wake<")).toBeLessThan(html.indexOf("heron"));
  });

  test("status gating and failure copy", () => {
    expect(canWakeMachine({ status: "paused" })).toBe(true);
    for (const status of ["running", "provisioning", "failed", "destroyed"] as const) {
      expect(canWakeMachine({ status })).toBe(false);
    }
    const declared = new ClientORPCError("PAYMENT_REQUIRED", {
      defined: true,
      status: 402,
      data: { reason: "vm_limit_reached", message: "Pause one first." },
    });
    expect(wakeErrorMessage(declared, "fallback")).toBe("Pause one first.");
    expect(wakeErrorMessage(new TypeError("offline"), "fallback")).toBe("fallback");
  });
});

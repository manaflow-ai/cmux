import { describe, expect, mock, test } from "bun:test";

const resolveCoderouterUsageTeam = mock(async () => ({
  ok: true as const,
  teamId: "raw-team-id",
  stackUserId: "raw-user-id",
}));
const captureCoderouterEvent = mock(() => {});

mock.module("../services/coderouter/requestContext", () => ({
  resolveCoderouterUsageTeam,
}));
mock.module("../services/coderouter/analytics", () => ({
  captureCoderouterEvent,
}));

const { POST } = await import("../app/api/coderouter/analytics/route");

const validProperties = {
  schema_version: 1,
  command: "agent",
  agent: "codex",
  mode: "routed",
  outcome: "success",
  failure_stage: "none",
  exit_code_class: "success",
  duration_bucket: "1s_to_5s",
  execution_context: "interactive",
  cli_version: "0.2.3",
};

describe("CodeRouter CLI analytics route", () => {
  test("authenticates scope and forwards only the closed schema", async () => {
    captureCoderouterEvent.mockClear();
    const response = await POST(new Request("https://cmux.test/api/coderouter/analytics", {
      method: "POST",
      headers: { authorization: "Bearer crt_test", "content-type": "application/json" },
      body: JSON.stringify({
        events: [{
          event: "coderouter_cli_command_completed",
          properties: validProperties,
        }],
      }),
    }));
    expect(response.status).toBe(204);
    expect(captureCoderouterEvent).toHaveBeenCalledWith({
      event: "coderouter_cli_command_completed",
      userId: "raw-user-id",
      teamId: "raw-team-id",
      properties: validProperties,
    });
  });

  test("rejects unknown fields and free-form values", async () => {
    captureCoderouterEvent.mockClear();
    const response = await POST(new Request("https://cmux.test/api/coderouter/analytics", {
      method: "POST",
      headers: { authorization: "Bearer crt_test", "content-type": "application/json" },
      body: JSON.stringify({
        events: [{
          event: "coderouter_cli_command_completed",
          properties: {
            ...validProperties,
            command: "/Users/private/project",
            prompt: "secret",
          },
        }],
      }),
    }));
    expect(response.status).toBe(400);
    expect(captureCoderouterEvent).not.toHaveBeenCalled();
  });

  test("bounds body and batch size", async () => {
    const events = Array.from({ length: 3 }, () => ({
      event: "coderouter_cli_command_started",
      properties: { ...validProperties, outcome: "started" },
    }));
    const response = await POST(new Request("https://cmux.test/api/coderouter/analytics", {
      method: "POST",
      headers: { authorization: "Bearer crt_test", "content-type": "application/json" },
      body: JSON.stringify({ events }),
    }));
    expect(response.status).toBe(400);
  });
});

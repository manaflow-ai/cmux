import { describe, expect, test } from "bun:test";

import { sanitizeCoderouterFailureContext } from "../services/coderouter/observability";

describe("CodeRouter failure telemetry context", () => {
  test("keeps only safe operational fields and the request join key", () => {
    expect(sanitizeCoderouterFailureContext({
      provider: "claude",
      operation: "select_claude_account",
      request_id: "request-123",
      team_id: "team-secret",
      upstream_account_id: "account-secret",
      authorization: "Bearer secret",
      token: "route-secret",
      prompt: "private prompt",
    })).toEqual({
      provider: "claude",
      operation: "select_claude_account",
      request_id: "request-123",
    });
  });
});

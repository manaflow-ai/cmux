import { describe, expect, test } from "bun:test";
import { RunApiHttpError } from "./runApi";
import { attachFailureState, attachTicketExpired } from "./RunBoard";

describe("Run board attach bridge", () => {
  test("classifies expired and replayed one-use tickets for clear retry copy", () => {
    expect(attachFailureState(new RunApiHttpError(410, "expired", "run_attach_expired"))).toBe("expired");
    expect(attachFailureState(new RunApiHttpError(409, "already consumed", "run_attach_replayed"))).toBe("replayed");
    expect(attachFailureState(new Error("bridge unavailable"))).toBe("error");
  });

  test("checks both ISO and Unix expiry forms before handing a ticket to the host", () => {
    const now = Date.parse("2026-10-16T20:00:00.000Z");
    expect(
      attachTicketExpired(
        { runId: "r", attemptId: "a", sessionId: "s", cursor: "1", expiresAt: "2026-10-16T19:59:59.000Z" },
        now,
      ),
    ).toBe(true);
    expect(
      attachTicketExpired(
        { runId: "r", attemptId: "a", sessionId: "s", cursor: "1", expiresAtUnix: now / 1000 + 60 },
        now,
      ),
    ).toBe(false);
    expect(attachTicketExpired({ runId: "r", attemptId: "a", sessionId: "s", cursor: "1" }, now)).toBe(false);
  });
});

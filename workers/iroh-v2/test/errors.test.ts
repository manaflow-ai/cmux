import { expect, test } from "bun:test";
import { errorSummary, failureDiagnostics, OperationError } from "../src/errors";

test("error summaries keep safe cause categories without SQL or bound parameters", () => {
  const error = new Error(
    `Failed to run the query 'UPDATE "socket_reservations" SET "output_bytes" = ? WHERE "user_id" = ?' params: 5,user-123`,
    { cause: new Error("socket_output_capacity: SQLITE_CONSTRAINT") },
  );
  const summary = errorSummary(error);
  expect(summary).toBe("Error <- Error:socket_output_capacity");
  expect(summary).not.toContain("user-123");
  expect(summary).not.toContain("socket_reservations");
});

test("diagnostics never include a custom error name or message", () => {
  const error = new Error("private request value");
  error.name = "credential-value";
  expect(errorSummary(error)).toBe("Error");
});

test("runtime failures map to fixed tags and platform flags", () => {
  const overloaded = Object.assign(new Error("Durable Object is overloaded. Requests queued for too long."), { retryable: true, overloaded: true });
  expect(errorSummary(overloaded)).toBe("Error:overloaded+retryable+overloaded");
  expect(errorSummary(new TypeError("Network connection lost."))).toBe("TypeError:network_lost");
});

test("classified operation errors carry no cause", () => {
  expect(failureDiagnostics(new OperationError("ticket_expired", 401, true))).toEqual({});
  expect(failureDiagnostics(new Error("x"))).toEqual({ cause: "Error" });
});

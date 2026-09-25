import { expect, test } from "bun:test";
import { errorSummary } from "../src/errors";

test("error summaries keep the cause chain without SQL or bound parameters", () => {
  const error = new Error(`Failed to run the query 'UPDATE "socket_reservations" SET "output_bytes" = ? WHERE "user_id" = ?' params: 5,user-123`, {
    cause: new Error("socket_output_capacity: SQLITE_CONSTRAINT"),
  });
  const summary = errorSummary(error);
  expect(summary).toBe("Error: Failed to run the query '…' <- Error: socket_output_capacity: SQLITE_CONSTRAINT");
  expect(summary).not.toContain("user-123");
  expect(summary).not.toContain("socket_reservations");
});

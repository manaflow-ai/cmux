import { expect, test } from "bun:test";
import { safeRunAdmissionError } from "../scripts/cloud-vm/run-admission-probe";

test("admission diagnostics keep SQLSTATE and identifiers without secret-bearing error details", () => {
  const error = new Error("postgres://secret-user:password@private-host/db", {
    cause: Object.assign(new Error("query insert values (customer-secret)"), {
      code: "23502", table_name: "run_attempts", column_name: "legacy_required", constraint_name: "attempt_check",
      query: "secret SQL", parameters: ["private token"], detail: "customer row",
    }),
  });
  expect(safeRunAdmissionError(error)).toEqual({ sqlstate: "23502", table: "run_attempts", column: "legacy_required", constraint: "attempt_check" });
});

test("admission diagnostics reject untrusted identifier fields and terminate cause cycles", () => {
  const error: Record<string, unknown> = { code: "secret", table: "postgres://secret", column: "customer value" };
  error.cause = error;
  expect(safeRunAdmissionError(error)).toEqual({});
});

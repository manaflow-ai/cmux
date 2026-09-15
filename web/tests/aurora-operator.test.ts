import { expect, test } from "bun:test";
import { createAuroraOperatorPool } from "../scripts/cloud-vm/aurora-operator.mjs";

test("operator rejects disabled certificate validation before creating an AWS token", () => {
  expect(() => createAuroraOperatorPool(process.cwd(), {
    AWS_REGION: "us-west-2",
    PGHOST: "database.invalid",
    PGPORT: "5432",
    PGUSER: "test",
    PGDATABASE: "test",
    CMUX_DB_SSL_REJECT_UNAUTHORIZED: "false",
  }, "test")).toThrow("Operator database connections require certificate validation");
});

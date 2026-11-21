import { expect, it } from "vitest";
import { StoreError } from "../../src/db/sql.ts";
import { unavailable } from "../../src/errors.ts";
import { LimitsUnavailable } from "../../src/limits/service.ts";
import { UpstreamError } from "../../src/upstream/client.ts";

// 2026-11-04: every production create answered a bare "temporarily unavailable" and only a log tail could say why.
// The 503 now names the dependency, with code-defined names only (never ids, SQL or causes).

it("names the failed dependency in the 503 message", () => {
  expect(unavailable(new UpstreamError({ operation: "createVm", status: 500 })).message).toBe(
    "The cmux VM service is temporarily unavailable (vm-provider.createVm (HTTP 500))",
  );
  expect(unavailable(new UpstreamError({ operation: "createVmReceipt", status: null })).message).toBe(
    "The cmux VM service is temporarily unavailable (vm-provider.createVmReceipt (no response))",
  );
  expect(unavailable(new StoreError({ operation: "countLive", cause: new Error("password=secret tenant=t1") })).message).toBe(
    "The cmux VM service is temporarily unavailable (database.countLive)",
  );
  expect(unavailable(new LimitsUnavailable({ cause: "tenant t1 ledger" })).message).toBe("The cmux VM service is temporarily unavailable (tenant-limits)");
  expect(unavailable("limits.rate").message).toBe("The cmux VM service is temporarily unavailable (limits.rate)");
});

it("keeps the bare message without a cause and passes a ServiceUnavailable through", () => {
  expect(unavailable().message).toBe("The cmux VM service is temporarily unavailable");
  const inner = unavailable("database.record");
  expect(unavailable(inner)).toBe(inner);
});

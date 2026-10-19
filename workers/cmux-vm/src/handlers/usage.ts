import { HttpApiBuilder } from "@effect/platform";
import { Effect } from "effect";
import { CmuxVmApi, UsageResponse, UsageTotals, UsageVmSummary } from "../api.ts";
import { MeteringLedger } from "../metering/ledger.ts";
import { badRequest, unavailable, vmNotFound } from "../errors.ts";
import { VmId } from "../lib/ids.ts";
import { withCaller } from "./common.ts";

const parseDate = (value: string, label: string) => {
  const time = Date.parse(value);
  return Number.isNaN(time) ? Effect.fail(badRequest(`${label} must be an ISO timestamp`)) : Effect.succeed(new Date(time));
};

export const usageHandlers = HttpApiBuilder.group(CmuxVmApi, "usage", (handlers) =>
  handlers.handle("getUsage", ({ urlParams }) =>
    withCaller("vm:read", "read", (caller) =>
      Effect.gen(function* () {
        const from = yield* parseDate(urlParams.from, "from");
        const to = yield* parseDate(urlParams.to, "to");
        if (to <= from) return yield* Effect.fail(badRequest("to must be after from"));
        const principal = caller.value;
        if (urlParams.vmId !== undefined && principal.resourceAllowlist !== null && !principal.resourceAllowlist.has(urlParams.vmId)) {
          return yield* Effect.fail(vmNotFound());
        }
        const ledger = yield* MeteringLedger;
        const report = yield* ledger
          .usage({
            tenantId: principal.tenantId,
            from,
            to,
            vmId: urlParams.vmId ?? null,
            allowedVmIds: principal.resourceAllowlist,
          })
          .pipe(Effect.mapError(() => unavailable()));
        return new UsageResponse({
          items: report.items.map((item) => new UsageVmSummary({ ...item, vmId: VmId.make(item.vmId) })),
          total: new UsageTotals(report.total),
        });
      }),
    ),
  ),
);

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import type { Freestyle } from "freestyle";

import { closeCloudDbForTests } from "../db/client";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { VmProviderOperationError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepositoryLive } from "../services/vms/repository";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { openVmCmuxRemote } from "../services/vms/workflows";

const serialTest = (test as typeof test & { serial: typeof test }).serial;
const dbTest = process.env.CMUX_DB_TEST === "1" ? serialTest : test.skip;
let sql: Sql;
beforeAll(() => {
  if (process.env.CMUX_DB_TEST === "1") {
    sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 1 });
  }
});
afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

// Team members reach the team's machines (#14818). A teammate who did not
// create a legacy team machine must get the same permanent answer as its
// creator, through the real team access check and the real driver.
describe("team access to a legacy machine", () => {
  dbTest("a teammate's cmux-remote attach answers 409 vm_recreate_required", async () => {
    const team = `recreate-${randomUUID()}`;
    const providerVmId = `${team}-legacy`;
    try {
      await sql`
        insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status, provider_metadata)
        values (${`${team}-creator`}, ${team}, 'team', 'freestyle', ${providerVmId}, 'snapshot-test', 'running',
          ${sql.json({ networkIpv4: "10.4.0.8" })})
      `;
      let providerAttachCalls = 0;
      const driver = new FreestyleProvider({ client: () => ({ vms: { ref: () => ({}) } }) as unknown as Freestyle });
      const gateway = {
        getStatus: () => Effect.succeed("running"),
        openCmuxRemote: (provider, vmId, options) => Effect.tryPromise({
          try: () => {
            providerAttachCalls += 1;
            return driver.openCmuxRemote(vmId, options);
          },
          catch: (cause) => new VmProviderOperationError({ provider, operation: "openCmuxRemote", cause }),
        }),
      } as Partial<VmProviderGatewayShape> as VmProviderGatewayShape;
      const result = await Effect.runPromise(openVmCmuxRemote({
        userId: `${team}-member`,
        billingTeamId: team,
        teamIds: [team],
        providerVmId,
        maxActiveVms: null,
        callerPlanId: "team",
      }).pipe(
        Effect.either,
        Effect.provide(Layer.mergeAll(
          VmRepositoryLive,
          Layer.succeed(VmProviderGateway, gateway),
          Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
        )),
      ));
      expect(providerAttachCalls).toBe(1);
      expect(result._tag).toBe("Left");
      const response = await vmWorkflowErrorResponse(result._tag === "Left" ? result.left : null);
      expect(response?.status).toBe(409);
      expect(await response!.json()).toMatchObject({ error: "vm_recreate_required", retryable: false });
    } finally {
      await sql`delete from cloud_vms where billing_team_id = ${team}`;
    }
  });
});

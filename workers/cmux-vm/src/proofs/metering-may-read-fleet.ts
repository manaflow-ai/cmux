import { defineProof, name, type Proof } from "@gdp-ts/core";
import { Data, Effect } from "effect";

/** Only the scheduled metering reconciliation may read provider fleet state. */
export interface MeteringMayReadFleet extends Proof<"MeteringMayReadFleet", ["scheduled"]> {}

const MeteringMayReadFleet = defineProof("MeteringMayReadFleet");
export const METERING_CRON = "*/5 * * * *";

/** A scheduled event from a cron other than the metering cron asked for the fleet proof. */
export class MeteringCronMismatch extends Data.TaggedError("MeteringCronMismatch")<{ readonly cron: string }> {}

/** The only minting path: the caller is named inside this scheduled-only helper. */
export const withMeteringMayReadFleet = <A>(controller: ScheduledController, run: (proof: MeteringMayReadFleet) => Effect.Effect<A>): Effect.Effect<A, MeteringCronMismatch> => {
  if (controller.cron !== METERING_CRON) return Effect.fail(new MeteringCronMismatch({ cron: controller.cron }));
  return name("scheduled", (caller) => run(MeteringMayReadFleet.prove(caller) as unknown as MeteringMayReadFleet));
};

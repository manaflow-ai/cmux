import { defineProof, type Named, type Proof } from "@gdp-ts/core";

/** Only the scheduled metering reconciliation may read provider fleet state. */
export interface MeteringMayReadFleet extends Proof<"MeteringMayReadFleet", ["scheduled"]> {}

const MeteringMayReadFleet = defineProof("MeteringMayReadFleet");

export const mintMeteringMayReadFleet = <C, N>(caller: Named<C, N>): MeteringMayReadFleet =>
  MeteringMayReadFleet.prove(caller) as unknown as MeteringMayReadFleet;

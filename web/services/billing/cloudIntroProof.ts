/**
 * The measured numbers the $1 pass shows beside its price. The pricing page
 * prints these and no other figure of its own; each one can be re-read from the
 * run named beside it. Pure: no React, no I/O.
 *
 * Re-read before changing a number: the run, the harness output, the table row.
 */

/**
 * A new Cloud machine, from the create call to the machine running, on staging.
 * Three runs of the zero-to-going harness (cmux#51203, scripts/cmux-next/zero-to-going.ts,
 * newcomer path, 2026-11-23): runs 45087298817 = 9.5 s, 45096444143 = 5.0 s,
 * 45098441768 = 4.0 s. The slowest of the three is shown, so the page never
 * claims better than the worst run.
 */
export const CLOUD_PROOF_NEW_MACHINE_SECONDS = 9.5;

/**
 * Ten machines asked for at once by one team on staging: 10 of 10 ready, none
 * refused, first ready in 12.2 s, last in 19.8 s. Run 45092680247 of the
 * cloud-value-demos probe (cmuxterm-hq, docs/cloud/value-demos.md, table row
 * "10 asked").
 */
export const CLOUD_PROOF_BURST_MACHINES = 10;
export const CLOUD_PROOF_BURST_LAST_READY_SECONDS = 19.8;

/**
 * A chat moved from one machine to another, then asked a question it was told
 * before the move: 158 s from the move command to its answer on the other
 * machine. One run (n=1), 2026-11-23, session 01a205d6-5982-771d-bf93-15a1138c62c4
 * (cmuxterm-hq docs/cloud/value-demos.md, demo 1).
 */
export const CLOUD_PROOF_CHAT_MOVE_SECONDS = 158;

export type CloudIntroProofStat = {
  readonly id: "newMachine" | "burst" | "chatMove";
  /** Seconds, as measured. */
  readonly seconds: number;
  /** Machines, when the figure is about a count. */
  readonly machines?: number;
};

export function cloudIntroProofStats(): readonly CloudIntroProofStat[] {
  return [
    { id: "newMachine", seconds: CLOUD_PROOF_NEW_MACHINE_SECONDS },
    { id: "burst", seconds: CLOUD_PROOF_BURST_LAST_READY_SECONDS, machines: CLOUD_PROOF_BURST_MACHINES },
    { id: "chatMove", seconds: CLOUD_PROOF_CHAT_MOVE_SECONDS },
  ];
}

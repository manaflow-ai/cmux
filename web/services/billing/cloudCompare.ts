/**
 * The comparison block on the cmux Cloud plans page (cmuxterm-hq RFD 0135,
 * "The pricing page"): three columns (your own server, the cloud tab of your
 * plan, cmux Cloud) and one row per claim. A row prints only when our cell is
 * measured true, with the run that measured it; every other row stays here
 * with `proof: null` and cannot print. Pure: no React, no I/O.
 *
 * To print a row: measure it, put the run in `proof`, and add its copy under
 * `nextCloudPlans.compare.rows.<id>` in en.json and ja.json (the test fails
 * for a proven row with no copy).
 */
import { CLOUD_PROOF_BURST_LAST_READY_SECONDS, CLOUD_PROOF_BURST_MACHINES } from "./cloudIntroProof";

export const CLOUD_COMPARE_ROW_IDS = [
  "firstReply",
  "moveChat",
  "claudeAndCodex",
  "agentsAtOnce",
  "unusedMonth",
  "phoneLaptopOff",
  "logins",
] as const;
export type CloudCompareRowId = (typeof CLOUD_COMPARE_ROW_IDS)[number];

/** Where our cell was measured true: the run or the code that shows it. */
export type CloudCompareProof = { readonly source: string };

export type CloudCompareRow = {
  readonly id: CloudCompareRowId;
  readonly proof: CloudCompareProof | null;
  /** Numbers the row's copy prints, from the measured constants. */
  readonly values?: Readonly<Record<string, number>>;
};

/** RFD 0135's rows in its order. Two are measured true today. */
export const CLOUD_COMPARE_ROWS: readonly CloudCompareRow[] = [
  // Gate 1 in RFD 0135: 20 of 20 fresh accounts get a real-model reply, p95 under 30 s. Not met.
  { id: "firstReply", proof: null },
  // Gate 3: the move in a build, timed, p95 under 10 s each way. The buttons are in no build yet.
  { id: "moveChat", proof: null },
  // Partly live; three connect paths are broken (RFD 0135, "Our edge").
  { id: "claudeAndCodex", proof: null },
  {
    id: "agentsAtOnce",
    proof: {
      source:
        "Staging run 45092680247 (cloud-value-demos, cmuxterm-hq docs/cloud/value-demos.md): 10 of 10 machines asked for at once were ready, the last in 19.8 s.",
    },
    values: {
      machines: CLOUD_PROOF_BURST_MACHINES,
      // The page says "within N seconds": round the measured time up, never down.
      seconds: Math.ceil(CLOUD_PROOF_BURST_LAST_READY_SECONDS),
    },
  },
  {
    id: "unusedMonth",
    proof: {
      source:
        "cmux-platform Plan.ts: a paused machine burns no machine minutes, so a month with every agent paused bills the plan's price alone (Margin.ts flatPlanBill); RFD 0135 'A paused agent is nearly free' (RFD 0071).",
    },
  },
  // Gate 4: read and reply from the phone with the Mac powered down. Today the phone goes through the Mac.
  { id: "phoneLaptopOff", proof: null },
  // Designed and partly live; production has no shared rule yet.
  { id: "logins", proof: null },
];

/** The rows that may print: only those whose cell is measured true. */
export function printableCompareRows(rows: readonly CloudCompareRow[] = CLOUD_COMPARE_ROWS): readonly CloudCompareRow[] {
  return rows.filter((row) => row.proof !== null);
}

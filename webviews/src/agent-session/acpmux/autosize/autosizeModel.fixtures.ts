// l10n-allow-file: gallery and test fixtures, not shipped UI.
import type { AutoSizeRow } from "./autosizeModel";

const small = { vcpu: 2, mem_gib: 4, disk_gib: 20, hourly_usd: 0.148 };
const medium = { vcpu: 4, mem_gib: 8, disk_gib: 20, hourly_usd: 0.296 };
const at = 1_795_600_000_000;

export const GREW_FOR_MEMORY: AutoSizeRow = {
  key: "rec_1:grow:1795600000000",
  machine: "vm_a",
  record: "rec_1",
  kind: "grow",
  cause: "memory",
  cause_text: "it ran out of memory",
  from: small,
  to: medium,
  hourly_usd: 0.296,
  rate_change_usd: 0.148,
  line: "Machine grew to 4 vCPU / 8 GiB (it ran out of memory), now $0.296 an hour",
  at_ms: at,
  last_at_ms: at,
  count: 1,
};

export const SHRANK_IDLE: AutoSizeRow = {
  ...GREW_FOR_MEMORY,
  key: "rec_1:shrink:1795600900000",
  machine: "vm_b",
  kind: "shrink",
  cause: "idle",
  cause_text: "it was idle",
  from: medium,
  to: small,
  hourly_usd: 0.148,
  rate_change_usd: -0.148,
  line: "Machine shrank to 2 vCPU / 4 GiB (it was idle), now $0.148 an hour",
  at_ms: at + 900_000,
  last_at_ms: at + 900_000,
};

export const HELD_AT_PLAN_LIMIT: AutoSizeRow = {
  ...GREW_FOR_MEMORY,
  key: "rec_1:hold:1795601800000",
  kind: "hold",
  hold: { code: "at_plan_limit" },
  from: small,
  to: undefined,
  hourly_usd: 0.148,
  rate_change_usd: 0,
  line: "This machine needs more than your plan allows (it ran out of memory); it stays at 2 vCPU / 4 GiB. Upgrade to Pro for 8 vCPU / 32 GiB.",
  offer: { do: "upgrade", plan: "next_pro", label: "Pro", vcpu: 8, mem_gib: 32 },
  at_ms: at + 1_800_000,
  last_at_ms: at + 3_000_000,
  count: 3,
};

/** The same hold seen from a shared view: no button. */
export const HELD_SHARED: AutoSizeRow = { ...HELD_AT_PLAN_LIMIT, offer: undefined, count: 1 };

export const HELD_UNKNOWN_CODE: AutoSizeRow = {
  ...HELD_SHARED,
  key: "rec_1:hold:1795602000000",
  hold: { code: "other", name: "resize_in_progress" },
  cause_text: "",
  line: "A resize is already running; it stays at 2 vCPU / 4 GiB.",
};

export const ROWS: AutoSizeRow[] = [GREW_FOR_MEMORY, HELD_AT_PLAN_LIMIT, SHRANK_IDLE];

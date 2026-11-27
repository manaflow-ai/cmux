import { Vm, type VmState } from "../api.ts";
import type { VmId } from "../lib/ids.ts";
import type { UpstreamVm } from "../upstream/client.ts";

const KNOWN_STATES: ReadonlyArray<VmState> = ["starting", "running", "pausing", "paused", "stopped"];

const stateOf = (state: string): VmState => KNOWN_STATES.find((known) => known === state) ?? "unknown";

/** Negative or absent provider limits read as "none". */
const limitOf = (value: number | null | undefined): number | null => (value === undefined || value === null || value < 0 ? null : value);

/** The public view: the cmux id, the ownership row's name and labels, and an allowlist of provider fields. */
export const toVm = (
  id: VmId,
  row: { readonly displayName: string | null; readonly labels: Readonly<Record<string, string>>; readonly committed?: boolean },
  upstream: UpstreamVm,
): Vm =>
  new Vm({
    id,
    displayName: row.displayName,
    labels: row.labels,
    state: stateOf(upstream.state),
    resources: {
      vcpus: upstream.resources.cpu,
      memoryMib: upstream.resources.memory,
      diskMib: upstream.resources.storage,
    },
    idleTimeoutSeconds: upstream.idleTimeoutSeconds ?? null,
    maxRunSeconds: limitOf(upstream.maxRunSeconds),
    autoDeleteSeconds: limitOf(upstream.autoDeleteSeconds),
    createdAt: upstream.createdAt,
    updatedAt: upstream.updatedAt,
    ...(row.committed === false ? { creation: "pending" as const } : {}),
  });

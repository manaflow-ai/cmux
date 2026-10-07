import { HostError, type HostOp } from "../../../test/latency/mock-host";
import type { BridgePageVariant } from "../format";

export function fixtureOps(state: BridgePageVariant): Record<string, HostOp> {
  return Object.fromEntries(
    [...new Set([...Object.keys(state.replies), ...Object.keys(state.failures ?? {}), ...(state.pending ?? [])])].map(
      (op) => [
        op,
        () => {
          if (state.pending?.includes(op)) return new Promise(() => {});
          const failure = state.failures?.[op];
          if (failure) throw new HostError(failure.code, failure.message);
          return structuredClone(state.replies[op]);
        },
      ],
    ),
  );
}

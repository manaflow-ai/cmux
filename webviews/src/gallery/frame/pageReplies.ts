import { HostError, type HostOp } from "../../../test/latency/mock-host";
import type { BridgePageVariant } from "../format";
import type { StageContext } from "./context";

export function fixtureOps(state: BridgePageVariant, appearance?: StageContext["appearance"]): Record<string, HostOp> {
  return Object.fromEntries(
    [...new Set([...Object.keys(state.replies), ...Object.keys(state.failures ?? {}), ...(state.pending ?? [])])].map(
      (op) => [
        op,
        () => {
          if (state.pending?.includes(op)) return new Promise(() => {});
          const failure = state.failures?.[op];
          if (failure) throw new HostError(failure.code, failure.message);
          const reply = structuredClone(state.replies[op]);
          return op === "cmux.editor.config" ? { ...(reply as object), appearance } : reply;
        },
      ],
    ),
  );
}

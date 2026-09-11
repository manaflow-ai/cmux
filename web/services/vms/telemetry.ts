import { currentVmRequestContext } from "./requestContext";
import {
  recordSpanError,
  setSpanAttributes,
  withSpan,
  type MaybeAttributes,
  type SpanCallback,
} from "../telemetry";

const VM_SUBSYSTEM = "vm-cloud";

export { recordSpanError, setSpanAttributes };
export type { MaybeAttributes, SpanCallback };

export async function withVmSpan<T>(
  name: string,
  attributes: MaybeAttributes,
  fn: SpanCallback<T>,
): Promise<T> {
  return withSpan(
    "cmux-vm",
    name,
    {
      "cmux.subsystem": VM_SUBSYSTEM,
      "cmux.runtime": "provider-driver",
      ...attributes,
    },
    (span) => {
      const progress = currentVmRequestContext()?.progress;
      const phase = name.includes("network") || name.includes("tunnel") ? "tunnel" : "provider";
      return progress ? progress.run(phase, () => Promise.resolve(fn(span))) : fn(span);
    },
  );
}

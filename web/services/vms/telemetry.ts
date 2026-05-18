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
    fn,
  );
}

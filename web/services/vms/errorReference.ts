import { activeTraceIds } from "../telemetry";
import { currentVmRequestContext } from "./requestContext";

/** Identifiers a Cloud VM caller can paste into support. */
export type VmErrorReference = {
  readonly requestId?: string;
  readonly traceId?: string;
};

export function currentVmErrorReference(): VmErrorReference {
  const traceId = activeTraceIds()?.traceId;
  const requestId = currentVmRequestContext()?.client.requestId ?? traceId;
  return {
    requestId,
    traceId,
  };
}

/** Add support identifiers to a JSON error payload without exposing secrets. */
export function withVmErrorReference<T extends Record<string, unknown>>(
  payload: T,
): T & { requestId?: string; traceId?: string } {
  const reference = currentVmErrorReference();
  const output = { ...payload } as T & { requestId?: string; traceId?: string };
  if (reference.requestId) output.requestId = reference.requestId;
  if (reference.traceId) output.traceId = reference.traceId;

  const ui = payload.ui;
  if (ui && typeof ui === "object" && !Array.isArray(ui)) {
    (output as Record<string, unknown>)["ui"] = {
      ...(ui as Record<string, unknown>),
      ...(reference.requestId ? { requestId: reference.requestId } : {}),
      ...(reference.traceId ? { traceId: reference.traceId } : {}),
    };
  }
  return output;
}

import { lookupPrice } from "./pricing";
import type { AcquireFailure, CredentialClass } from "./types";

export function managedAcquireFailure(input: {
  credentialClass: CredentialClass;
  model?: string;
  balanceMicros: number;
  unflushedEstimateMicros: number;
}): AcquireFailure | null {
  if (input.credentialClass !== "managed") return null;
  if (!lookupPrice(input.model)) return { ok: false, error: "model_not_priced" };
  if (input.balanceMicros - input.unflushedEstimateMicros <= 0) {
    return { ok: false, error: "insufficient_credits" };
  }
  return null;
}

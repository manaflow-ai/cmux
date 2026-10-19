import { Context, Effect, Layer } from "effect";

/** A VM lifecycle fact the metering ledger records (cx-b4h.20). */
export type UsageEvent =
  | { readonly kind: "vm_started"; readonly tenantId: string; readonly upstreamVmId: string; readonly at: Date; readonly vcpus: number; readonly memoryMb: number; readonly storageMb: number }
  | { readonly kind: "vm_stopped"; readonly tenantId: string; readonly upstreamVmId: string; readonly at: Date; readonly reason: "pause" | "stop" | "delete" }
  | { readonly kind: "vm_resized"; readonly tenantId: string; readonly upstreamVmId: string; readonly at: Date; readonly vcpus: number; readonly memoryMb: number; readonly storageMb: number }
  | { readonly kind: "vm_woken_by_identity"; readonly tenantId: string; readonly upstreamVmId: string; readonly at: Date };

export class UsageRecorder extends Context.Tag("cmux-vm/UsageRecorder")<
  UsageRecorder,
  { readonly record: (event: UsageEvent) => Effect.Effect<void> }
>() {}

/** Records nothing; the default until the metering layer is wired. */
export const noopUsageRecorderLayer = Layer.succeed(UsageRecorder, { record: () => Effect.void });

import * as Effect from "effect/Effect";
import { CMUX_TUI_SESSION, cmuxTuiAttachBundleCommand, parseCmuxTuiAttachBundle } from "./drivers/cmuxTuiDaemon";
import {
  hugeBlueInspectionView,
  type HugeBlueInspectionMode,
  type HugeBlueInspectionObservation,
  type HugeBlueInspectionView,
} from "./hugeBlueInspection";
import { VmProviderGateway } from "./providerGateway";
import { getVm, requireUserVm, type VmWorkflowProgram } from "./workflows";

const PROBE_TIMEOUT_MS = 10_000;

/**
 * Inspect one of the caller's registered machines without changing it.
 *
 * Ownership is checked first in every mode, so a disabled or unconfigured
 * deployment still answers 404 for a machine the caller cannot see. Only a
 * running machine is probed, so inspection never wakes a paused one, and
 * the probe is the attach bundle's read-only half: daemon build, enrolled
 * devices and the trusted-carrier listener. Nothing is minted or recorded.
 */
export function inspectVmForHugeBlue(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly mode: HugeBlueInspectionMode;
  readonly deviceFingerprint?: string;
  readonly now?: () => Date;
}): VmWorkflowProgram<HugeBlueInspectionView> {
  return Effect.gen(function* () {
    const observation = yield* observe(input);
    return hugeBlueInspectionView({
      host: input.providerVmId,
      session: CMUX_TUI_SESSION,
      observation,
      now: (input.now ?? (() => new Date()))(),
    });
  });
}

function observe(input: Parameters<typeof inspectVmForHugeBlue>[0]): VmWorkflowProgram<HugeBlueInspectionObservation> {
  return Effect.gen(function* () {
    const access = {
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      teamIds: input.teamIds,
      providerVmId: input.providerVmId,
    };
    if (input.mode !== "enabled") {
      yield* requireUserVm(access);
      return { kind: input.mode === "disabled" ? "disabled" : "unconfigured" } as const;
    }
    const entry = yield* getVm(access);
    if (entry.status !== "running") return { kind: "not_running" } as const;
    const row = yield* requireUserVm(access);
    const providers = yield* VmProviderGateway;
    const command = cmuxTuiAttachBundleCommand({ deviceFingerprint: input.deviceFingerprint });
    const probe = yield* providers.exec(row.provider, input.providerVmId, command, {
      timeoutMs: PROBE_TIMEOUT_MS,
      providerMetadata: row.providerMetadata,
      // The daemon's state dir belongs to its user; the bundle drops to it.
      asRoot: true,
    }).pipe(Effect.either);
    if (probe._tag === "Left" || probe.right.exitCode !== 0) return { kind: "probe_failed" } as const;
    return {
      kind: "probed",
      bundle: parseCmuxTuiAttachBundle(probe.right.stdout, row.provider, input.providerVmId, input.deviceFingerprint),
      deviceFingerprintGiven: input.deviceFingerprint !== undefined,
    } as const;
  });
}

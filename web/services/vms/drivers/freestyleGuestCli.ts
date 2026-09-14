import { randomBytes } from "node:crypto";
import { Clock, Data, Effect, Exit } from "effect";
import type { Freestyle } from "freestyle";
import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH } from "../guestCli";
import type { GuestPromptIdentity } from "../guestPrompt";
import { guestCliInstallCommand } from "./guestCliInstallCommand";

export type FreestyleClientFactory = (timeoutMs?: number, signal?: AbortSignal) => Freestyle;
export const GUEST_INSTALL_DEADLINE_MS = 45_000;
const CLEANUP_DEADLINE_MS = 10_000;
type InstallStage = "upload" | "install" | "validate" | "verify" | "prompt" | "publish";
type InstallOutcome = "missing_status" | "invalid_status" | "provider_timeout" | "guest_exit"
  | "cancelled" | "transport_timeout" | "transport" | "deadline";

export class GuestCliInstallError extends Data.TaggedError("GuestCliInstallError")<{
  readonly stage: InstallStage;
  readonly outcome: InstallOutcome;
  readonly exitCode?: number | null;
  readonly diagnostic?: string;
  readonly elapsedMs?: number;
  readonly cause?: unknown;
  readonly cleanupCause?: unknown;
}> {
  get message(): string {
    return `guest cmux shim ${this.stage}: ${this.outcome}`
      + (typeof this.exitCode === "number" ? ` (exit ${this.exitCode})` : "")
      + (this.diagnostic ? `: ${this.diagnostic}` : "");
  }
}

function guestFailure(result: unknown): GuestCliInstallError | undefined {
  const response = result && typeof result === "object" ? result as Record<string, unknown> : {};
  const status = response.statusCode;
  if (status === 0) return;
  const outcome: InstallOutcome = status === undefined ? "missing_status"
    : status === null ? "provider_timeout"
      : typeof status === "number" && Number.isInteger(status) ? "guest_exit" : "invalid_status";
  const failure: { stage: InstallStage; diagnostic?: string } = { stage: "install" };
  // Only our own bounded diagnostic record enters telemetry. Arbitrary guest
  // stdout/stderr may contain private data and is deliberately not logged.
  const marker = typeof response.stderr === "string"
    ? response.stderr.split("\n").find((line) => line.startsWith("CMUX_GUEST_INSTALL_FAILURE=")) : undefined;
  if (marker && marker.length < 512) {
    try {
      const detail = JSON.parse(marker.slice("CMUX_GUEST_INSTALL_FAILURE=".length));
      if (["validate", "verify", "prompt", "publish"].includes(detail.stage)) failure.stage = detail.stage;
      if (typeof detail.error === "string" && /^[A-Za-z]{1,40}$/.test(detail.error)) {
        failure.diagnostic = detail.error
          + (Number.isInteger(detail.errno) ? ` errno=${detail.errno}` : "")
          + (Number.isInteger(detail.exitCode) ? ` exit=${detail.exitCode}` : "");
      }
    } catch { /* Unknown provider output is not evidence of an install stage. */ }
  }
  return new GuestCliInstallError({
    ...failure, outcome,
    exitCode: status === null || typeof status === "number" ? status : undefined,
  });
}

function transportFailure(stage: InstallStage, cause: unknown): GuestCliInstallError {
  if (cause instanceof GuestCliInstallError) return cause;
  const name = cause instanceof Error ? cause.name : undefined;
  return new GuestCliInstallError({
    stage, cause,
    outcome: name === "AbortError" ? "cancelled" : name === "TimeoutError" ? "transport_timeout" : "transport",
  });
}

/** One overall deadline includes upload, exec and SDK background polling. */
export function installFreestyleGuestCli(client: FreestyleClientFactory, vmId: string, identity?: GuestPromptIdentity) {
  return Effect.gen(function* () {
    const started = yield* Clock.currentTimeMillis;
    const temporaryPath = `${GUEST_CMUX_SHIM_PATH}.tmp-${randomBytes(12).toString("hex")}`;
    let stage: InstallStage = "upload";
    let cleanupCause: unknown;
    const install = Effect.tryPromise({
      try: async (signal) => {
        const vm = client(GUEST_INSTALL_DEADLINE_MS, signal).vms.ref(vmId);
        await vm.fs.writeTextFile(temporaryPath, GUEST_CMUX_SHIM, { mode: 0o755 });
        signal.throwIfAborted();
        stage = "install";
        const result = await vm.exec({
          command: guestCliInstallCommand(temporaryPath, identity), timeoutMs: 30_000, linuxUser: "root",
        });
        const failure = guestFailure(result);
        if (failure) throw failure;
      },
      catch: (cause) => transportFailure(stage, cause),
    }).pipe(Effect.timeoutFail({
      duration: GUEST_INSTALL_DEADLINE_MS,
      onTimeout: () => new GuestCliInstallError({ stage, outcome: "deadline" }),
    }));
    const cleanup = Effect.tryPromise({
      // A fresh request owns cleanup; an aborted install signal cannot cancel it.
      try: (signal) => client(CLEANUP_DEADLINE_MS, signal).vms.ref(vmId).fs.remove(temporaryPath),
      catch: (cause) => cause,
    }).pipe(
      Effect.interruptible,
      Effect.timeoutFail({ duration: CLEANUP_DEADLINE_MS, onTimeout: () => new Error("guest upload cleanup deadline") }),
      Effect.catchAll((cause) => Effect.sync(() => { cleanupCause = cause; })),
    );
    yield* Effect.acquireUseRelease(
      Effect.void,
      () => install,
      (_, exit) => Exit.isFailure(exit) ? cleanup : Effect.void,
    ).pipe(Effect.catchAll((error) => Clock.currentTimeMillis.pipe(Effect.flatMap((finished) =>
      Effect.fail(new GuestCliInstallError({
        stage: error.stage,
        outcome: error.outcome,
        elapsedMs: finished - started,
        exitCode: error.exitCode,
        diagnostic: error.diagnostic,
        cause: error.cause,
        cleanupCause,
      }))
    ))));
    return { elapsedMs: (yield* Clock.currentTimeMillis) - started };
  });
}

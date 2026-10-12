import type { ProviderId } from "./drivers";
import type { VmImageKind } from "./images/resolver";

/** The state the Cloud clients can render without probing the guest. */
export type ComputerUseStatus = "unsupported" | "starting" | "ready" | "failed";

export type ComputerUseReadiness = {
  readonly status: ComputerUseStatus;
  /** The guest implementation used by the three supported agent clients. */
  readonly driver: "cua-driver";
  readonly error?: {
    readonly code: string;
    readonly message: string;
  };
};

type ComputerUseInput = {
  readonly provider: ProviderId | string;
  readonly kind: VmImageKind;
  readonly status: string;
};

/**
 * Computer-use readiness is deliberately derived from durable VM facts. List
 * requests must stay cheap and must not exec a command in every guest just to
 * paint the Cloud sidebar. The first action still starts/heals the driver and
 * reports its precise error through the MCP tool response.
 */
export function computerUseReadinessFor(input: ComputerUseInput): ComputerUseReadiness {
  const driver = "cua-driver" as const;
  if (input.provider !== "freestyle") {
    return {
      status: "unsupported",
      driver,
      error: {
        code: "provider_unsupported",
        message: "Computer use is available on Cloud desktop machines.",
      },
    };
  }
  if (input.kind !== "desktop") {
    return {
      status: "unsupported",
      driver,
      error: {
        code: "desktop_required",
        message: "Computer use requires a desktop machine.",
      },
    };
  }
  switch (input.status.toLowerCase()) {
    case "running":
      return { status: "ready", driver };
    case "provisioning":
    case "paused":
      return { status: "starting", driver };
    case "failed":
      return {
        status: "failed",
        driver,
        error: {
          code: "vm_failed",
          message: "The desktop machine failed to start.",
        },
      };
    case "destroyed":
      return {
        status: "failed",
        driver,
        error: {
          code: "vm_destroyed",
          message: "The desktop machine is no longer available.",
        },
      };
    default:
      return { status: "starting", driver };
  }
}

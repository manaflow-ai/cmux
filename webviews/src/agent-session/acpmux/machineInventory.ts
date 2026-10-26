import type { Environment } from "./environments";

/** Current-account Cloud rows from the app's MachineRegistry, never from peer names. */
export function cloudEnvironments(reply: unknown): Environment[] {
  const value = reply as { loaded?: unknown; signedIn?: unknown; machines?: unknown } | undefined;
  if (value?.loaded !== true || value.signedIn !== true || !Array.isArray(value.machines)) return [];
  return value.machines.flatMap((raw) => {
    if (!raw || typeof raw !== "object") return [];
    const machine = raw as Record<string, unknown>;
    if (typeof machine.id !== "string" || !machine.id || typeof machine.name !== "string" || !machine.name) return [];
    if (machine.state === "destroyed") return [];
    const status =
      machine.state === "paused"
        ? "paused"
        : machine.state === "provisioning" ||
            ["requesting", "creating", "booting", "connecting"].includes(String(machine.phase))
          ? "connecting"
          : machine.connected === true
            ? "connected"
            : machine.connected === false
              ? "offline"
              : undefined;
    return [
      {
        id: machine.id,
        label: machine.name,
        kind: "cloud" as const,
        native: true,
        ...(status ? { status: status as NonNullable<Environment["status"]> } : {}),
        ...(typeof machine.connected === "boolean" ? { connected: machine.connected } : {}),
      },
    ];
  });
}

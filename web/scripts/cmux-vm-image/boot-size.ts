// No imports: the fast-checks runner tests this without the web dependencies installed.
/** The chat start size (2 vCPU / 4096 MiB / 20480 MiB, cloud-journey.ts CHAT_START_SIZE), as the guest reads it. */
export const BASE_BOOT_LIMIT = { cpu: 2, memoryMb: 4096, rootMb: 20480 } as const;
/** Null when a clone of the snapshot booted at most the chat start size on every axis; else what it booted at. */
export function oversizedBoot(shape: { cpu: number; memoryMb: number; rootMb: number }): string | null {
  const over = (["cpu", "memoryMb", "rootMb"] as const).filter((k) => !(shape[k] <= BASE_BOOT_LIMIT[k]));
  return over.length === 0 ? null : `a clone booted at ${shape.cpu} vCPU / ${shape.memoryMb} MiB / root ${shape.rootMb} MiB, over the chat start size on ${over.join(", ")}: the snapshot carries a grown size`;
}

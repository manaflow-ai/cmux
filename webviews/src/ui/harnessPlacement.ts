// One placement policy for the model picker and its ordinary Settings row.
export const HARNESS_PLACEMENT_KEY = "agentPane.display.harnessPlacement";
export type HarnessPlacement = "symbols" | "left" | "top" | "compact";

export function harnessPlacement(value: unknown): HarnessPlacement | null {
  return value === "symbols" || value === "left" || value === "top" || value === "compact" ? value : null;
}

// A saved normal preference wins, including an explicit symbols choice. Until one is saved,
// keep the existing Debug preference. A fresh install retains the top symbols row.
export function resolveHarnessPlacement(saved: unknown, legacy: unknown, managed?: unknown): HarnessPlacement {
  return harnessPlacement(managed) ?? harnessPlacement(saved) ?? harnessPlacement(legacy) ?? "symbols";
}

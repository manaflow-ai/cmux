// Dev page only (dev.tsx `?recents=demo`): recent model and effort combos across the mock
// catalog's families, so the picker variants show their recents and layers on first open.
import type { Combo } from "./ComposerPickers";

const DEMO: Combo[] = [
  { harness: "claude", model: "claude-opus-5-5", effort: "high", effortName: "High" },
  { harness: "claude", model: "claude-sonnet-5-5", effort: "medium", effortName: "Medium" },
  { harness: "claude", model: "claude-opus-4-6", effort: "low", effortName: "Low" },
  { harness: "claude", model: "claude-haiku-4-5", effort: "low", effortName: "Low" },
  { harness: "codex", model: "gpt-6-astra", effort: "high", effortName: "High" },
  { harness: "codex", model: "gpt-5.5-codex", effort: "medium", effortName: "Medium" },
  { harness: "codex", model: "o3", effort: "high", effortName: "High" },
  { harness: "codex", model: "qwen3-coder", effort: "low", effortName: "Low" },
];

export function seedDevRecents(): void {
  try {
    localStorage.setItem("cmux.acpmux.recentModels", JSON.stringify(DEMO));
  } catch {
    // Blocked storage: the variants open without recents.
  }
}

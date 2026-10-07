import type { ProviderInfo } from "./types";

export function codexModelLabel(provider: Pick<ProviderInfo, "displayName" | "id"> | undefined): string {
  if (provider?.id === "codex") {
    return "GPT-5.5";
  }
  return provider?.displayName ?? "GPT-5.5";
}

export function providerBadgeLabel(provider: Pick<ProviderInfo, "displayName" | "id">): string {
  const displayName = provider.displayName;
  const lower = displayName.toLowerCase();
  if (provider.id === "claude" || lower.includes("claude")) {
    return "Cl";
  }
  if (provider.id === "opencode" || lower.includes("open")) {
    return "O";
  }
  if (lower === "pi" || lower.includes(" pi")) {
    return "Pi";
  }
  return displayName.trim().slice(0, 1).toUpperCase() || "C";
}

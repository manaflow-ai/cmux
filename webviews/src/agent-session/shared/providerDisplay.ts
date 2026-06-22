import type { ProviderInfo } from "./types";

export function modelLabel(provider: Pick<ProviderInfo, "displayName"> | undefined): string {
  return provider?.displayName ?? "";
}

export function providerBadgeLabel(provider: Pick<ProviderInfo, "displayName" | "id" | "providerDisplayName">): string {
  const displayName = provider.providerDisplayName ?? provider.displayName;
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

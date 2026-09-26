export type PricingFeatureVisibility = {
  readonly vault: boolean;
  readonly hostedNetworking: boolean;
};

export type PlanColumn = "free" | "go" | "pro" | "max" | "team" | "enterprise";

export type CompareRow = {
  label: string;
  free: string;
  go: string;
  pro: string;
  max: string;
  team: string;
  enterprise: string;
  vault?: boolean;
  hostedNetworking?: boolean;
};

export type FaqItem = {
  q: string;
  a: string;
  vault?: boolean;
};

export type PricingActionSize = "default" | "compact";

export function visibleProFeatures({
  base,
  vault,
  hostedNetworking,
  visibility,
}: {
  base: string[];
  vault: string[];
  hostedNetworking: string[];
  visibility: PricingFeatureVisibility;
}) {
  let features = visibility.vault
    ? [...base.slice(0, 2), ...vault, ...base.slice(2)]
    : base;
  if (visibility.hostedNetworking) {
    features = [
      ...features.slice(0, -1),
      ...hostedNetworking,
      ...features.slice(-1),
    ];
  }
  return features;
}

export function visibleCompareRows(
  rows: CompareRow[],
  visibility: PricingFeatureVisibility,
) {
  return rows.filter(
    (row) =>
      (visibility.vault || !row.vault) &&
      (visibility.hostedNetworking || !row.hostedNetworking),
  );
}

export function visibleFaqItems(
  items: FaqItem[],
  visibility: PricingFeatureVisibility,
) {
  return items.filter((item) => visibility.vault || !item.vault);
}

export function pricingActionClassName(
  variant: "primary" | "secondary" | "disabled",
  size: PricingActionSize = "default",
): string {
  const base =
    "inline-flex w-full items-center justify-center whitespace-nowrap font-medium";
  const sizeClass =
    size === "compact"
      ? "px-3 py-1.5 text-xs"
      : "min-h-12 px-5 py-3 text-[15px]";
  if (variant === "primary") {
    return `${base} ${sizeClass} bg-foreground transition-opacity hover:opacity-85`;
  }
  if (variant === "secondary") {
    return `${base} ${sizeClass} border border-border text-foreground transition-colors hover:bg-code-bg`;
  }
  return `${base} ${sizeClass} border border-border text-muted`;
}

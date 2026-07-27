import type { CSSProperties } from "react";

type SearchParams = Record<string, string | string[] | undefined>;

export function appPricingFirstParam(
  value: string | string[] | undefined,
): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}

export function appPricingAppearance(params: SearchParams): "light" | "dark" {
  return appPricingFirstParam(params.appearance) === "dark" ? "dark" : "light";
}

export function appPricingPageBackground(
  params: SearchParams,
  appearance: "light" | "dark",
): string {
  const background = appPricingFirstParam(params.background);
  if (background && /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(background)) {
    return background;
  }
  return appearance === "dark" ? "#272822" : "#fafafa";
}

export function appPricingStyle(
  appearance: "light" | "dark",
  pageBackground: string,
): CSSProperties {
  if (appearance === "dark") {
    return {
      "--foreground": "#ededed",
      "--muted": "#a3a3a3",
      "--border": "rgba(255, 255, 255, 0.18)",
      "--code-bg": "rgba(24, 24, 24, 0.72)",
      "--background": pageBackground,
      "--pricing-sticky-bg": pageBackground,
      "--button-foreground": pageBackground,
      backgroundColor: pageBackground,
      colorScheme: "dark",
    } as CSSProperties;
  }
  return {
    "--foreground": "#171717",
    "--muted": "#5f6368",
    "--border": "rgba(0, 0, 0, 0.14)",
    "--code-bg": "rgba(245, 245, 245, 0.78)",
    "--background": pageBackground,
    "--pricing-sticky-bg": pageBackground,
    "--button-foreground": "#ffffff",
    backgroundColor: pageBackground,
    colorScheme: "light",
  } as CSSProperties;
}

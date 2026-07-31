import type { CSSProperties } from "react";

type SearchParams = Record<string, string | string[] | undefined>;

export type AppPricingTheme = {
  appearance: "light" | "dark";
  background: string;
  foreground: string;
  accent: string;
};

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

export function appPricingTheme(params: SearchParams): AppPricingTheme {
  const appearance = appPricingAppearance(params);
  const background = appPricingPageBackground(params, appearance);
  return {
    appearance,
    background,
    foreground: appPricingColorParam(
      params.foreground,
      appearance === "dark" ? "#ededed" : "#171717",
    ),
    accent: appPricingColorParam(
      params.accent,
      appearance === "dark" ? "#0091ff" : "#0088ff",
    ),
  };
}

export function appPricingStyle(theme: AppPricingTheme): CSSProperties {
  return {
    "--ghostty-background": theme.background,
    "--ghostty-foreground": theme.foreground,
    "--cmux-product-blue": theme.accent,
    "--foreground": "var(--ghostty-foreground)",
    "--muted":
      "color-mix(in srgb, var(--ghostty-foreground) 62%, var(--ghostty-background))",
    "--border":
      "color-mix(in srgb, var(--ghostty-foreground) 18%, transparent)",
    "--code-bg":
      "color-mix(in srgb, var(--ghostty-foreground) 8%, var(--ghostty-background))",
    "--background": "var(--ghostty-background)",
    "--pricing-sticky-bg": "var(--ghostty-background)",
    "--button-foreground": "var(--ghostty-background)",
    backgroundColor: "var(--ghostty-background)",
    colorScheme: theme.appearance,
  } as CSSProperties;
}

function appPricingColorParam(
  value: string | string[] | undefined,
  fallback: string,
): string {
  const color = appPricingFirstParam(value);
  return color && /^#[0-9a-fA-F]{6}$/.test(color) ? color : fallback;
}

import type { CSSProperties } from "react";

type SearchParams = Record<string, string | string[] | undefined>;

export type AppPricingTheme = {
  appearance: "light" | "dark";
  background: string;
  foreground: string;
  accent: string;
  accentOnBackground: string;
  accentOnForeground: string;
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
  if (background && /^#[0-9a-fA-F]{6}$/.test(background)) {
    return background;
  }
  return appearance === "dark" ? "#272822" : "#fafafa";
}

export function appPricingTheme(params: SearchParams): AppPricingTheme {
  const appearance = appPricingAppearance(params);
  const background = appPricingPageBackground(params, appearance);
  const foreground = appPricingColorParam(
    params.foreground,
    appearance === "dark" ? "#ededed" : "#171717",
  );
  const accent = appPricingColorParam(
    params.accent,
    appearance === "dark" ? "#0091ff" : "#0088ff",
  );
  return {
    appearance,
    background,
    foreground,
    accent,
    accentOnBackground: appPricingColorParam(
      params.accent_on_background,
      appPricingContrastAdjustedAccent(accent, background),
    ),
    accentOnForeground: appPricingColorParam(
      params.accent_on_foreground,
      appPricingContrastAdjustedAccent(accent, foreground),
    ),
  };
}

export function appPricingStyle(theme: AppPricingTheme): CSSProperties {
  return {
    "--ghostty-background": theme.background,
    "--ghostty-foreground": theme.foreground,
    "--cmux-product-blue": theme.accent,
    "--cmux-product-blue-on-background": theme.accentOnBackground,
    "--cmux-product-blue-on-foreground": theme.accentOnForeground,
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

type RGB = readonly [red: number, green: number, blue: number];

export function appPricingContrastAdjustedAccent(
  preferredColor: string,
  backgroundColor: string,
  minimumContrast = 4.5,
): string {
  const preferred = appPricingRGB(preferredColor);
  const background = appPricingRGB(backgroundColor);
  if (!preferred || !background) return preferredColor;
  if (appPricingContrastRatio(preferred, background) >= minimumContrast) {
    return preferredColor;
  }

  const candidates = [0, 255]
    .map((target) => {
      for (let step = 1; step <= 255; step += 1) {
        const mix = (component: number) =>
          Math.floor((component * (255 - step) + target * step) / 255);
        const color: RGB = [
          mix(preferred[0]),
          mix(preferred[1]),
          mix(preferred[2]),
        ];
        const contrast = appPricingContrastRatio(color, background);
        if (contrast >= minimumContrast) {
          const distanceSquared = color.reduce(
            (sum, component, index) =>
              sum + (component - preferred[index]) ** 2,
            0,
          );
          return { color, contrast, distanceSquared };
        }
      }
      return null;
    })
    .filter(
      (
        candidate,
      ): candidate is {
        color: RGB;
        contrast: number;
        distanceSquared: number;
      } =>
        candidate !== null,
    )
    .sort(
      (lhs, rhs) =>
        lhs.distanceSquared - rhs.distanceSquared
        || rhs.contrast - lhs.contrast,
    );

  return candidates[0] ? appPricingHex(candidates[0].color) : preferredColor;
}

function appPricingRGB(color: string): RGB | null {
  if (!/^#[0-9a-fA-F]{6}$/.test(color)) return null;
  const value = Number.parseInt(color.slice(1), 16);
  return [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];
}

function appPricingHex([red, green, blue]: RGB): string {
  return `#${[red, green, blue]
    .map((component) => component.toString(16).padStart(2, "0"))
    .join("")
    .toUpperCase()}`;
}

function appPricingContrastRatio(foreground: RGB, background: RGB): number {
  const foregroundLuminance = appPricingRelativeLuminance(foreground);
  const backgroundLuminance = appPricingRelativeLuminance(background);
  const lighter = Math.max(foregroundLuminance, backgroundLuminance);
  const darker = Math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

function appPricingRelativeLuminance(color: RGB): number {
  const [red, green, blue] = color.map((component) => {
    const srgb = component / 255;
    return srgb <= 0.03928
      ? srgb / 12.92
      : ((srgb + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

/**
 * Shared class for inline text links across the marketing and docs pages.
 * Foreground text (near-white in dark mode) with a dedicated, higher-contrast
 * underline that meets WCAG 1.4.11 (>=3:1) with margin; the underline brightens
 * to full foreground on hover.
 */
export const LINK_CLASS =
  "text-foreground underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

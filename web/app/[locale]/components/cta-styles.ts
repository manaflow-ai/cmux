// Shared styling for the primary pill CTA (the "Download for Mac" button and
// the iOS "Get the beta" button), so they stay identical.
export const ctaButtonBase =
  "inline-flex items-center whitespace-nowrap rounded-full font-medium bg-foreground hover:opacity-85 transition-opacity";
export const ctaButtonDefaultSize = "gap-2.5 px-5 py-2.5 text-[15px]";
export const ctaButtonSmallSize = "gap-2 px-4 py-1.5 text-xs";
export const ctaButtonStyle = {
  color: "var(--background)",
  textDecoration: "none",
} as const;

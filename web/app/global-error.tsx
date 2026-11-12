"use client";

import { RouteErrorView, useErrorBoundaryLocale } from "./components/error-boundary";
import "./globals.css";

/**
 * Last resort when a root or locale layout throws. It replaces the root
 * layout, so it renders its own document and never shows Next's blank
 * "Application error" screen.
 */
export default function GlobalError({ error, reset, retry }: { error: Error; reset: () => void; retry?: () => void }) {
  const locale = useErrorBoundaryLocale();
  return (
    <html lang={locale} dir={locale === "ar" ? "rtl" : "ltr"} suppressHydrationWarning>
      <body className="bg-background font-sans text-foreground antialiased">
        <RouteErrorView boundary="global" error={error} retry={retry ?? reset} />
      </body>
    </html>
  );
}

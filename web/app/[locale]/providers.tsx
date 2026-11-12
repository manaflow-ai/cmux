"use client";

import { ThemeProvider } from "next-themes";
import { PostHogProvider } from "./posthog";

/**
 * Providers for every localized page. Hexclave is deliberately absent: it is
 * mounted only where a page reads the session (`StackProviders` in the
 * dashboard layout; the join page and `/handler` mount their own), so
 * marketing pages never download it and a Hexclave outage cannot reach them.
 */
export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <ThemeProvider attribute="class" defaultTheme="dark" disableTransitionOnChange>
      <PostHogProvider>{children}</PostHogProvider>
    </ThemeProvider>
  );
}

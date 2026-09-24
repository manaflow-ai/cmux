"use client";

import { ThemeProvider } from "next-themes";
import { PostHogProvider } from "./posthog";

/**
 * Shared by every localized page, including the public landing pages. It must
 * not mount Hexclave: its client fetches the session on load and throws into
 * the tree when that fetch fails. Routes that need auth mount their own
 * provider (dashboard, handler), where auth failures are contained.
 */
export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <ThemeProvider attribute="class" defaultTheme="dark" disableTransitionOnChange>
      <PostHogProvider>{children}</PostHogProvider>
    </ThemeProvider>
  );
}

"use client";

import { ThemeProvider } from "next-themes";
import { PostHogProvider } from "./posthog";

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <ThemeProvider attribute="class" defaultTheme="dark" disableTransitionOnChange>
      <PostHogProvider>
        {children}
      </PostHogProvider>
    </ThemeProvider>
  );
}

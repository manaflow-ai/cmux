"use client";

import { StackProvider } from "@hexclave/next";
import { ThemeProvider } from "next-themes";
import { stackClientApp } from "../lib/stack-client";
import { PostHogProvider } from "./posthog";
import { IsolatedStackAuthObserver } from "./stack-auth-observer";

/**
 * Every localized page loads Hexclave for its analytics. Nothing here may
 * let a Hexclave failure reach the page: the only hook that reads Hexclave
 * state sits behind its own error boundary.
 */
export function Providers({ children }: { children: React.ReactNode }) {
  const content = (
    <ThemeProvider attribute="class" defaultTheme="dark" disableTransitionOnChange>
      <PostHogProvider>{children}</PostHogProvider>
    </ThemeProvider>
  );
  return stackClientApp ? (
    <StackProvider app={stackClientApp}>
      <IsolatedStackAuthObserver />
      {content}
    </StackProvider>
  ) : (
    content
  );
}

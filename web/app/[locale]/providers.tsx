"use client";

import { StackProvider } from "@stackframe/stack";
import { ThemeProvider } from "next-themes";
import { stackClientApp } from "../lib/stack-client";
import { PostHogProvider } from "./posthog";

export function Providers({ children }: { children: React.ReactNode }) {
  const content = (observesStackAuth: boolean) => (
    <ThemeProvider attribute="class" defaultTheme="dark" disableTransitionOnChange>
      <PostHogProvider observesStackAuth={observesStackAuth}>
        {children}
      </PostHogProvider>
    </ThemeProvider>
  );
  return stackClientApp
    ? <StackProvider app={stackClientApp}>{content(true)}</StackProvider>
    : content(false);
}

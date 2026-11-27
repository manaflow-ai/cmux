"use client";

import { StackProvider } from "@hexclave/next";
import { stackClientApp } from "../lib/stack-client";
import { IsolatedStackAuthObserver } from "./stack-auth-observer";

/**
 * Hexclave session for the signed-in parts of the site (the dashboard).
 *
 * Marketing pages do not mount this: the Hexclave client and its UI kit are
 * about half a megabyte of compressed JavaScript, and those pages only need
 * the analytics identity, which the PostHog tracker already re-checks on
 * navigation, focus, visibility, `online` and cross-tab storage changes.
 */
export function StackProviders({ children }: { children: React.ReactNode }) {
  return stackClientApp ? (
    <StackProvider app={stackClientApp}>
      <IsolatedStackAuthObserver />
      {children}
    </StackProvider>
  ) : (
    children
  );
}

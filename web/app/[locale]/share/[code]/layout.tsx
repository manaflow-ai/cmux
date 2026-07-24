import { StackProvider, StackTheme } from "@stackframe/stack";
import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { privateSharePageMetadata } from "@/services/analytics/sharePrivacy";

// Share codes are invitation credentials. Keep them out of referrers and
// search indexes even if a link is pasted onto a crawlable page.
export const metadata: Metadata = privateSharePageMetadata;

// Auth redirects are owned by the page (it needs the requested code for the
// sign-in return path); this layout only provides the Stack context.
export default function ShareLayout({ children }: { children: React.ReactNode }) {
  if (!isStackConfigured()) {
    redirect("/");
  }
  return (
    <StackProvider app={getStackServerApp()}>
      <StackTheme>{children}</StackTheme>
    </StackProvider>
  );
}

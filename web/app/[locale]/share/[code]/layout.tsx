import { StackProvider, StackTheme } from "@stackframe/stack";
import { redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";

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

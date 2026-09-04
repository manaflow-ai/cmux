import { StackProvider, StackTheme } from "@stackframe/stack";

import { getStackServerApp, isStackConfigured } from "../../lib/stack";

export const instant = false;

/**
 * Wraps only the handler routes cmux has not rebuilt yet (MFA, team
 * invitations, CLI confirmation, account settings). Keeping the provider here
 * rather than on the shared `/handler` layout is what keeps the sign-in page
 * free of the client SDK.
 */
export default function StackHandlerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  if (!isStackConfigured()) return children;
  const stackServerApp = getStackServerApp();
  return stackServerApp ? (
    <StackProvider app={stackServerApp}>
      <StackTheme>{children}</StackTheme>
    </StackProvider>
  ) : (
    children
  );
}

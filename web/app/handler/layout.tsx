import { Suspense } from "react";
import { StackProvider, StackTheme } from "@stackframe/stack";
import { getStackServerApp, isStackConfigured } from "../lib/stack";

export default function HandlerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  if (!isStackConfigured()) {
    return children;
  }

  const stackServerApp = getStackServerApp();
  return (
    <Suspense>
      {stackServerApp ? (
        <StackProvider app={stackServerApp}>
          <StackTheme>{children}</StackTheme>
        </StackProvider>
      ) : (
        children
      )}
    </Suspense>
  );
}

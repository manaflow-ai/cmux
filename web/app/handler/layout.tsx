import { Suspense } from "react";
import { StackProvider, StackTheme } from "@stackframe/stack";
import { getStackHandlerApp, isStackHandlerConfigured } from "../lib/stack";

export default function HandlerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  if (!isStackHandlerConfigured()) {
    return children;
  }

  const stackHandlerApp = getStackHandlerApp();
  return (
    <Suspense>
      {stackHandlerApp ? (
        <StackProvider app={stackHandlerApp}>
          <StackTheme>{children}</StackTheme>
        </StackProvider>
      ) : (
        children
      )}
    </Suspense>
  );
}

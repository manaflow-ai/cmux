import { StackProvider, StackTheme } from "@hexclave/next";
import { IsolatedStackAuthObserver } from "../[locale]/stack-auth-observer";
import { getStackServerApp, isStackConfigured } from "../lib/stack";

export const instant = false;

export default function HandlerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  if (!isStackConfigured()) {
    return children;
  }

  const stackServerApp = getStackServerApp();
  return stackServerApp ? (
    <StackProvider app={stackServerApp}>
      <StackTheme>
        <IsolatedStackAuthObserver />
        {children}
      </StackTheme>
    </StackProvider>
  ) : (
    children
  );
}

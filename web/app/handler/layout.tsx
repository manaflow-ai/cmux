import { Suspense } from "react";
import { StackProvider, StackTheme } from "@stackframe/stack";
import { stackServerApp } from "../lib/stack";

export default function HandlerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body>
        <Suspense>
          <StackProvider app={stackServerApp}>
            <StackTheme>{children}</StackTheme>
          </StackProvider>
        </Suspense>
      </body>
    </html>
  );
}

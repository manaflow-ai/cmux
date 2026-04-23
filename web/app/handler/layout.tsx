import { Suspense } from "react";
import { Geist, Geist_Mono } from "next/font/google";
import { StackProvider, StackTheme } from "@stackframe/stack";
import { stackServerApp } from "../lib/stack";
import "../globals.css";

// Load the same Geist fonts the rest of the site uses so the Stack Auth
// handler pages don't fall back to the browser's default serif. globals.css
// is imported to pull in the Tailwind layer that declares the font-sans
// utility these variables feed into.
const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export default function HandlerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${geistSans.variable} ${geistMono.variable} font-sans antialiased`}
      >
        <Suspense>
          <StackProvider app={stackServerApp}>
            <StackTheme>{children}</StackTheme>
          </StackProvider>
        </Suspense>
      </body>
    </html>
  );
}

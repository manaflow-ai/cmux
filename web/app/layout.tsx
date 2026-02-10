import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { Providers } from "./providers";
import { ThemeToggle } from "./theme";
import { DevPanel } from "./components/spacing-control";
import { SiteFooter } from "./components/nav-links";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "cmux — The terminal built for multitasking",
  description:
    "Native macOS terminal built on Ghostty. Vertical tabs, notification rings when agents need attention, split panes, and a socket API for automation.",
  keywords: [
    "terminal",
    "macOS",
    "coding agents",
    "Claude Code",
    "Codex",
    "Ghostty",
    "AI",
  ],
  openGraph: {
    title: "cmux — The terminal built for multitasking",
    description:
      "Native macOS terminal built on Ghostty. Vertical tabs, notification rings, split panes, and a socket API.",
    url: "https://cmux.dev",
    siteName: "cmux",
    type: "website",
  },
  twitter: {
    card: "summary",
    title: "cmux — The terminal built for multitasking",
    description:
      "Native macOS terminal built on Ghostty. Vertical tabs, notification rings, split panes, and a socket API.",
  },
  metadataBase: new URL("https://cmux.dev"),
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${geistSans.variable} ${geistMono.variable} font-sans antialiased`}
      >
        <Providers>
          <div className="fixed top-2 right-4 z-50">
            <ThemeToggle />
          </div>
          {children}
          <SiteFooter />
          <DevPanel />
        </Providers>
      </body>
    </html>
  );
}

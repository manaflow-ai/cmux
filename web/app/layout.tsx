import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { Providers } from "./providers";

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
    "Native macOS terminal built on Ghostty. Works with Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, and any CLI tool. Vertical tabs, notification rings, split panes, and a socket API.",
  keywords: [
    "terminal",
    "macOS",
    "coding agents",
    "Claude Code",
    "Codex",
    "OpenCode",
    "Gemini CLI",
    "Kiro",
    "Aider",
    "Ghostty",
    "AI",
    "terminal for AI agents",
  ],
  openGraph: {
    title: "cmux — The terminal built for multitasking",
    description:
      "Native macOS terminal for AI coding agents. Works with Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, and any CLI tool.",
    url: "https://cmux.dev",
    siteName: "cmux",
    type: "website",
  },
  twitter: {
    card: "summary",
    title: "cmux — The terminal built for multitasking",
    description:
      "Native macOS terminal for AI coding agents. Works with Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, and any CLI tool.",
  },
  metadataBase: new URL("https://cmux.dev"),
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "cmux",
    operatingSystem: "macOS",
    applicationCategory: "DeveloperApplication",
    url: "https://cmux.dev",
    downloadUrl:
      "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg",
    description:
      "Native macOS terminal built on Ghostty. Works with Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, and any CLI tool. Vertical tabs, notification rings, split panes, and a socket API.",
    keywords:
      "terminal, macOS, Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, AI coding agents, Ghostty",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  };

  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script
          dangerouslySetInnerHTML={{
            __html: `(function(){try{var t=localStorage.getItem("theme");if(t==="light")return;if(t==="system"&&window.matchMedia("(prefers-color-scheme:light)").matches)return;document.documentElement.classList.add("dark")}catch(e){}})()`,
          }}
        />
      </head>
      <body
        className={`${geistSans.variable} ${geistMono.variable} font-sans antialiased`}
      >
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
        <Providers>
          {children}
          <SiteFooter />
          <DevPanel />
        </Providers>
      </body>
    </html>
  );
}

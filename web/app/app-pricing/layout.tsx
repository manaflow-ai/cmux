import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "../globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "cmux Pro",
  description: "cmux Pro pricing inside the cmux app.",
};

export default function AppPricingLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning style={{ background: "transparent" }}>
      <head>
        <meta name="theme-color" content="transparent" />
        <style>{`
          :root {
            --background: transparent;
            --foreground: #171717;
            --muted: #5f6368;
            --border: rgba(0, 0, 0, 0.14);
            --code-bg: rgba(245, 245, 245, 0.78);
            --button-foreground: #ffffff;
          }
          html, body { background: transparent !important; }
        `}</style>
      </head>
      <body
        className={`${geistSans.variable} ${geistMono.variable} font-sans antialiased`}
        style={{ background: "transparent" }}
      >
        {children}
      </body>
    </html>
  );
}

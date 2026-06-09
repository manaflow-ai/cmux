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
  title: "devbox.new",
  description: "Create a new cmux devbox from a prompt.",
  metadataBase: new URL("https://devbox.new"),
  alternates: {
    canonical: "https://devbox.new",
  },
  openGraph: {
    title: "devbox.new",
    description: "Create a new cmux devbox from a prompt.",
    url: "https://devbox.new",
    siteName: "devbox.new",
    type: "website",
  },
};

export default function DevboxLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${geistSans.variable} ${geistMono.variable} bg-background font-sans text-foreground antialiased`}
      >
        {children}
      </body>
    </html>
  );
}

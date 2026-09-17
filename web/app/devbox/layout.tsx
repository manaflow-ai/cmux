import type { Metadata } from "next";
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
    <div className="bg-background font-sans text-foreground antialiased">
      {children}
    </div>
  );
}

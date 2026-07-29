import type { Metadata, Viewport } from "next";

export const metadata: Metadata = {
  title: "Welcome to cmux Pro",
  description: "Your next steps after upgrading to cmux Pro.",
};

export const viewport: Viewport = {
  themeColor: "transparent",
};

export default function AppProWelcomeLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
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
      {children}
    </>
  );
}
